import BSpaceCore
import Foundation
import Network
import Security

/// The local channel captured video and sound travel to the page on:
/// a WebSocket over TLS on `127.0.0.1`, for one page and one share.
///
/// `LocalIdentity` says why it is TLS and where the certificate comes from,
/// `MediaChannelGate` who may speak. The channel carries whole binary
/// messages and knows nothing of what is in them.
public final class LocalMediaChannel {
    public enum Failure: Error, Equatable {
        /// The system did not take the channel's key and certificate.
        case identityRefused(OSStatus)
        /// The window shows no page of a server: there is nobody to open a
        /// channel to.
        case noPage
        /// The channel could not listen.
        case notListening(String)
    }

    /// What the page needs to connect.
    public struct Endpoint: Equatable {
        public let url: String
        public let token: String
    }

    /// Called on the main queue when the page has said the token: what is
    /// sent from now on reaches it.
    public var onClientConnected: (() -> Void)?
    /// Called on the main queue when the page's connection is gone. The
    /// channel is of no more use: nothing else can take its place.
    public var onClientDisconnected: (() -> Void)?
    /// Called on the main queue with each message of the page after the token.
    public var onMessage: ((Data) -> Void)?

    public let identity: LocalIdentity
    /// The port the channel listens on, once it does.
    public private(set) var port: Int?

    private let pageOrigin: String?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-media-channel")
    /// On `queue`.
    private var gate = MediaChannelGate()
    private var connections: [Int: NWConnection] = [:]
    private var nextConnection = 0
    /// What `send` reads from any thread.
    private let lock = NSLock()
    private var client: NWConnection?
    private var bytesWaiting = 0

    /// - Parameter pageOrigin: the origin of the page the channel is for.
    ///   A handshake from any other is refused before it can say a token.
    public init(pageOrigin: String?) throws {
        self.pageOrigin = pageOrigin
        identity = try LocalIdentity()

        var items: CFArray?
        let status = SecPKCS12Import(identity.pkcs12 as CFData, [
            kSecImportExportPassphrase: identity.password,
            kSecImportToMemoryOnly: true,
        ] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let imported = first[kSecImportItemIdentity as String],
              CFGetTypeID(imported as CFTypeRef) == SecIdentityGetTypeID(),
              let secIdentity = sec_identity_create(imported as! SecIdentity)
        else { throw Failure.identityRefused(status) }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(LocalIdentity.host), port: .any)
        parameters.acceptLocalOnly = true

        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value
            let allowed = MediaChannelGate.isOriginAllowed(origin, page: pageOrigin)
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.notListening(error.localizedDescription)
        }
    }

    /// Starts listening. The completion is called once, on the main queue,
    /// with what the page needs to connect.
    public func start(_ completion: @escaping (Result<Endpoint, Failure>) -> Void) {
        var hasAnswered = false
        let answer: (Result<Endpoint, Failure>) -> Void = { result in
            guard !hasAnswered else { return }
            hasAnswered = true
            DispatchQueue.main.async { completion(result) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port?.rawValue else {
                    answer(.failure(.notListening("the listener has no port")))
                    return
                }
                let token = self.gate.token
                DispatchQueue.main.async {
                    self.port = Int(port)
                }
                answer(.success(Endpoint(url: "wss://\(LocalIdentity.host):\(port)/", token: token)))
            case .failed(let error):
                answer(.failure(.notListening(error.localizedDescription)))
            case .cancelled:
                answer(.failure(.notListening("the channel was closed")))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    /// Sends one binary message to the page. Safe from any thread. False when
    /// there is no page to send to, or when the page reads too slowly and the
    /// message was dropped rather than queued behind what already waits.
    @discardableResult
    public func send(_ message: Data) -> Bool {
        lock.lock()
        guard let client, bytesWaiting + message.count <= MediaChannelGate.mostBytesWaiting else {
            lock.unlock()
            return false
        }
        bytesWaiting += message.count
        lock.unlock()

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "media", metadata: [metadata])
        let size = message.count
        client.send(content: message, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.bytesWaiting -= size
            self.lock.unlock()
        })
        return true
    }

    /// Sends one text message to the page: what says how to read the binary
    /// ones. Safe from any thread. It is never dropped; false when there is
    /// no page to send to.
    @discardableResult
    public func send(text: String) -> Bool {
        lock.lock()
        let client = self.client
        lock.unlock()
        guard let client else { return false }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "control", metadata: [metadata])
        client.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
        return true
    }

    /// Closes the channel and everything connected to it.
    public func stop() {
        listener.cancel()
        queue.async { [self] in
            connections.values.forEach { $0.cancel() }
            connections = [:]
        }
        lock.lock()
        client = nil
        lock.unlock()
    }

    // MARK: Connections, on `queue`

    private func accept(_ connection: NWConnection) {
        let id = nextConnection
        nextConnection += 1
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveFirstMessage(of: id, on: connection)
                // A connection that says nothing is closed.
                self.queue.asyncAfter(deadline: .now() + MediaChannelGate.timeToSpeak) { [weak self] in
                    guard let self, self.gate.client != id, self.connections[id] != nil else { return }
                    self.close(id)
                }
            case .failed, .cancelled:
                self.close(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveFirstMessage(of id: Int, on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            guard error == nil, let content else {
                self.close(id)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let text = metadata?.opcode == .text ? String(data: content, encoding: .utf8) : nil
            guard self.gate.firstMessage(from: id, text: text) == .accept else {
                self.close(id)
                return
            }
            self.lock.lock()
            self.client = connection
            self.bytesWaiting = 0
            self.lock.unlock()
            DispatchQueue.main.async { self.onClientConnected?() }
            self.receive(from: id, on: connection)
        }
    }

    private func receive(from id: Int, on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                self.close(id)
                return
            }
            if let content, !content.isEmpty {
                DispatchQueue.main.async { self.onMessage?(content) }
            }
            self.receive(from: id, on: connection)
        }
    }

    private func close(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.cancel()
        let wasClient = gate.client == id
        gate.closed(id)
        guard wasClient else { return }
        lock.lock()
        client = nil
        lock.unlock()
        DispatchQueue.main.async { self.onClientDisconnected?() }
    }
}
