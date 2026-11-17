// Writes the LevelDB fixture the BSpaceCore tests read:
// Tests/BSpaceCoreTests/Fixtures/chromium-local-storage/leveldb.
//
// The fixture is a database in the layout Chromium uses for localStorage,
// written by the real LevelDB library (through classic-level), so that the
// Swift reader is tested against what LevelDB writes and not against a writer
// that shares its author's reading of the format. Everything in it is made up.
//
// It is committed; run this only to change what the fixture holds, and change
// ChromiumLocalStorageTests.swift with it. classic-level is not a dependency
// of the repository:
//
//   mkdir /tmp/fixture && cd /tmp/fixture && npm install classic-level@3.0.0
//   NODE_PATH=/tmp/fixture/node_modules node <repo>/packages/desktop-macos/scripts/make-leveldb-fixture.mjs
//
// What the database is made to contain, file by file:
//   - a table at a deeper level, after a full compaction (Snappy blocks, keys
//     stored as differences from the key before, several blocks);
//   - a newer table above it that overwrites one of its keys and deletes
//     another (a tombstone in a table);
//   - a write-ahead log with a value longer than one 32 KB log block, an
//     overwrite and a deletion that no table has seen;
//   - a manifest whose edits add tables and take them away again.

import { createRequire } from 'node:module';
import { mkdirSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { ClassicLevel } = require('classic-level');

const target = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'Tests',
  'BSpaceCoreTests',
  'Fixtures',
  'chromium-local-storage',
  'leveldb',
);

/** A string the way Chromium stores it: Latin-1 when it fits, else UTF-16. */
function encoded(text) {
  const latin1 = [...text].every((character) => character.codePointAt(0) <= 0xff);
  return Buffer.concat([
    Buffer.from([latin1 ? 1 : 0]),
    Buffer.from(text, latin1 ? 'latin1' : 'utf16le'),
  ]);
}

function itemKey(storageKey, key) {
  return Buffer.concat([Buffer.from(`_${storageKey}\0`, 'latin1'), encoded(key)]);
}

const CHAT = 'https://chat.example.test';
const LAN = 'http://192.168.1.20:3000';
const EMBEDDED = 'https://embed.example.test/^0https://chat.example.test';

async function open() {
  const db = new ClassicLevel(target, { keyEncoding: 'buffer', valueEncoding: 'buffer' });
  await db.open();
  return db;
}

/** Closing and opening again makes LevelDB turn the log into a table. */
async function reopened(db) {
  await db.close();
  return open();
}

rmSync(target, { recursive: true, force: true });
mkdirSync(target, { recursive: true });

let db = await open();

// 1. The oldest data: ends up in the deepest table.
let batch = db.batch();
batch.put(Buffer.from('VERSION'), Buffer.from('1'));
batch.put(Buffer.from(`META:${CHAT}`), Buffer.from([0x08, 0x90, 0xa1, 0xd2, 0x03, 0x10, 0x40]));
batch.put(Buffer.from(`METAACCESS:${CHAT}`), Buffer.from([0x08, 0x90, 0xa1, 0xd2, 0x03]));
batch.put(itemKey(CHAT, 'backspace_token'), encoded('fixture-token-not-a-secret'));
batch.put(itemKey(CHAT, 'backspace-language'), encoded('en'));
batch.put(itemKey(CHAT, 'greeting'), encoded('Привет, мир 👋'));
batch.put(itemKey(CHAT, 'черновик:1'), encoded('текст черновика'));
batch.put(itemKey(CHAT, 'empty'), encoded(''));
batch.put(itemKey(CHAT, 'deleted-in-table'), encoded('gone'));
batch.put(itemKey(CHAT, 'deleted-in-log'), encoded('gone too'));
batch.put(itemKey(CHAT, 'changed-in-log'), encoded('first'));
batch.put(itemKey(CHAT, 'repetitive'), encoded('abcdefgh'.repeat(1500)));
for (let index = 0; index < 300; index += 1) {
  const name = String(index).padStart(3, '0');
  batch.put(itemKey(CHAT, `filler:${name}`), encoded(`value number ${name}`));
}
batch.put(itemKey(LAN, 'backspace_token'), encoded('lan-token'));
batch.put(itemKey(EMBEDDED, 'player'), encoded('partitioned'));
await batch.write();

db = await reopened(db);
await db.put(itemKey(CHAT, 'second-table'), encoded('1'));
// Opening writes a fresh manifest that lists the tables as they are. What
// follows happens in one session, so this manifest also records it: a table
// added, then all three merged into one and taken away.
db = await reopened(db);
await db.put(itemKey(CHAT, 'third-table'), encoded('1'));
await db.compactRange(Buffer.from([0x00]), Buffer.from([0xff]));

// 2. A newer table over the compacted one. Compacting a range above every key
//    only moves what is in memory into a table.
batch = db.batch();
batch.put(itemKey(CHAT, 'backspace-language'), encoded('ru'));
batch.del(itemKey(CHAT, 'deleted-in-table'));
batch.put(itemKey(CHAT, 'filler:150'), encoded('changed in the newer table'));
await batch.write();
await db.compactRange(Buffer.from([0x7e, 0x7e]), Buffer.from([0x7e, 0x7e, 0x7e]));

// 3. What stays in the write-ahead log.
batch = db.batch();
batch.put(itemKey(CHAT, 'long'), encoded('0123456789'.repeat(4000)));
batch.put(itemKey(CHAT, 'changed-in-log'), encoded('second'));
batch.del(itemKey(CHAT, 'deleted-in-log'));
batch.put(itemKey(CHAT, 'log-only'), encoded('yes'));
await batch.write();
await db.close();

// LevelDB's own lock and message files: the reader does not use them.
for (const name of readdirSync(target)) {
  if (name === 'LOCK' || name.startsWith('LOG')) rmSync(join(target, name));
}
console.log(readdirSync(target).join('\n'));
