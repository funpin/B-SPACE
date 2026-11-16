import {
  ArrowLeft, ArrowRight, AtSign, Ban, Bell, BellOff, Check, ChevronDown, ChevronLeft, ChevronRight, ChevronUp,
  CircleAlert, CircleHelp, Compass, Copy, Crown, Download, Ellipsis, EllipsisVertical, ExternalLink, Eye, EyeOff,
  FileText, Folder, Globe, Hash, Headphones, HeadphoneOff, Image as ImageIcon, Info, Keyboard, LayoutGrid, Link, Lock,
  LogOut, Maximize, MessageSquare, Mic, MicOff, Minimize, Minus, Monitor, Palette, Paperclip, Pencil, Phone,
  PhoneOff, Pin, Play, Plus, RefreshCw, Reply, ScreenShare, ScreenShareOff, Search, Send, Settings, Shield, Smile,
  Sticker, Trash2, TriangleAlert, Upload, User, UserMinus, UserPlus, Users, Video, VideoOff, Volume2, VolumeX,
  Wifi, WifiOff, X, Unplug, createLucideIcon,
  ArrowDown, ArrowUp, BadgeCheck, Bookmark, Bot, Calendar, Camera, CheckCheck, Circle, CircleCheck, CircleMinus, CirclePlus, CircleX, Clock, Cloud, CloudOff, Code, CornerUpLeft, Database, Ear, EarOff, File, FileUp, Filter, Flag, FolderPlus, Gamepad2, Gift, GripVertical, Hand, HardDrive, Heart, History, House, ImagePlus, Inbox, Key, Link2, List, LogIn, Mail, Megaphone, Menu, MessageCircle, MessagesSquare, MonitorOff, MonitorUp, Moon, MousePointer2, Music, Network, PanelLeft, PanelRight, Pause, PictureInPicture2, Power, Radio, RotateCcw, Save, Server, Share2, ShieldCheck, Signal, SlidersHorizontal, Smartphone, Sparkles, Square, Star, Sun, Tag, ThumbsUp, Unlink, Unlock, UserCheck, UserX, Volume1, Zap, ZoomIn, ZoomOut, Expand, Shrink, Move, Languages, Bug, Wrench, Rocket, PartyPopper, Angry, Frown, Laugh, Meh, LoaderCircle, SwitchCamera, ChartNoAxesColumn,
  type LucideIcon,
} from 'lucide-react';

/**
 * A microphone with an exclamation mark: the member has no microphone access.
 * Lucide has only the plain and the struck-through microphone, and the
 * struck-through one already means "muted". Drawn on Lucide's 24px grid in
 * its outline style: its `mic` moved two units left, the mark beside it.
 */
const MicAlert = createLucideIcon('MicAlert', [
  ['path', { d: 'M10 19v3', key: 'stand' }],
  ['path', { d: 'M17 10v2a7 7 0 0 1-14 0v-2', key: 'cradle' }],
  ['rect', { x: '7', y: '2', width: '6', height: '13', rx: '3', key: 'capsule' }],
  ['path', { d: 'M21 3v6', key: 'mark' }],
  ['path', { d: 'M21 13h.01', key: 'dot' }],
]);

/**
 * The signal meter: three capsules of rising height, the lit ones solid and
 * the rest faint. A member's network is weak (two lit) or gone (one lit):
 * the red one keeps a lit capsule so it stays as visible as the amber one.
 *
 * Solid shapes are the one exception to "outline only" in this file, chosen
 * by the owner over thin bars and over outlined capsules: the mark is drawn
 * at the 13px of a participant row, where an outline of this size thins to a
 * thread and a stroke-only bar reads as a harsh stick. A lit capsule against
 * faint ones is also a level, not a state shown by filling a glyph, which is
 * what the outline rule is about.
 */
const UNLIT_CAPSULE = '0.3';
const CAPSULES = [
  { x: '3', y: '13', height: '8' },
  { x: '9.5', y: '8', height: '13' },
  { x: '16', y: '3', height: '18' },
] as const;

function signalMeter(name: string, lit: number): LucideIcon {
  return createLucideIcon(name, CAPSULES.map((capsule, index) => ['rect', {
    ...capsule,
    width: '5',
    rx: '2.5',
    fill: 'currentColor',
    stroke: 'none',
    ...(index < lit ? {} : { opacity: UNLIT_CAPSULE }),
    key: `capsule-${index}`,
  }]));
}

const SignalWeak = signalMeter('SignalWeak', 2);
const SignalLost = signalMeter('SignalLost', 1);

/**
 * The one way an icon enters a screen (docs/brand/brandbook.md §8). Lucide,
 * outline only, 1.75 stroke at every size, colour from `currentColor`. State
 * is shown by the button's colour and ground, never by a filled glyph.
 *
 * Screens name an icon instead of importing it, so the set stays one list:
 * adding an icon is one import and one line in `ICONS`. Named imports keep
 * the bundle to the glyphs listed here. A lint rule forbids importing
 * `lucide-react` anywhere else.
 */
const ICONS = {
  'arrow-left': ArrowLeft,
  'arrow-right': ArrowRight,
  'at-sign': AtSign,
  ban: Ban,
  bell: Bell,
  'bell-off': BellOff,
  check: Check,
  'chevron-down': ChevronDown,
  'chevron-left': ChevronLeft,
  'chevron-right': ChevronRight,
  'chevron-up': ChevronUp,
  'circle-alert': CircleAlert,
  'circle-help': CircleHelp,
  compass: Compass,
  copy: Copy,
  crown: Crown,
  download: Download,
  ellipsis: Ellipsis,
  'ellipsis-vertical': EllipsisVertical,
  'external-link': ExternalLink,
  eye: Eye,
  'eye-off': EyeOff,
  'file-text': FileText,
  folder: Folder,
  globe: Globe,
  hash: Hash,
  headphones: Headphones,
  'headphone-off': HeadphoneOff,
  image: ImageIcon,
  info: Info,
  keyboard: Keyboard,
  'layout-grid': LayoutGrid,
  link: Link,
  lock: Lock,
  'log-out': LogOut,
  maximize: Maximize,
  'message-square': MessageSquare,
  mic: Mic,
  'mic-off': MicOff,
  minimize: Minimize,
  minus: Minus,
  monitor: Monitor,
  palette: Palette,
  paperclip: Paperclip,
  pencil: Pencil,
  phone: Phone,
  'phone-off': PhoneOff,
  pin: Pin,
  play: Play,
  plus: Plus,
  'refresh-cw': RefreshCw,
  reply: Reply,
  'screen-share': ScreenShare,
  'screen-share-off': ScreenShareOff,
  search: Search,
  send: Send,
  settings: Settings,
  shield: Shield,
  smile: Smile,
  sticker: Sticker,
  'trash-2': Trash2,
  'triangle-alert': TriangleAlert,
  upload: Upload,
  user: User,
  'user-minus': UserMinus,
  'user-plus': UserPlus,
  users: Users,
  video: Video,
  'video-off': VideoOff,
  'volume-2': Volume2,
  'volume-x': VolumeX,
  wifi: Wifi,
  'wifi-off': WifiOff,
  x: X,
  'arrow-down': ArrowDown,
  'arrow-up': ArrowUp,
  'badge-check': BadgeCheck,
  bookmark: Bookmark,
  bot: Bot,
  calendar: Calendar,
  camera: Camera,
  'switch-camera': SwitchCamera,
  chart: ChartNoAxesColumn,
  'check-check': CheckCheck,
  circle: Circle,
  'circle-check': CircleCheck,
  'circle-minus': CircleMinus,
  'circle-plus': CirclePlus,
  'circle-x': CircleX,
  clock: Clock,
  cloud: Cloud,
  'cloud-off': CloudOff,
  code: Code,
  'corner-up-left': CornerUpLeft,
  database: Database,
  ear: Ear,
  'ear-off': EarOff,
  file: File,
  'file-up': FileUp,
  filter: Filter,
  flag: Flag,
  'folder-plus': FolderPlus,
  'gamepad-2': Gamepad2,
  gift: Gift,
  'grip-vertical': GripVertical,
  hand: Hand,
  'hard-drive': HardDrive,
  heart: Heart,
  history: History,
  house: House,
  'image-plus': ImagePlus,
  inbox: Inbox,
  key: Key,
  'link-2': Link2,
  list: List,
  'log-in': LogIn,
  mail: Mail,
  megaphone: Megaphone,
  menu: Menu,
  'message-circle': MessageCircle,
  'messages-square': MessagesSquare,
  'monitor-off': MonitorOff,
  'monitor-up': MonitorUp,
  moon: Moon,
  'mouse-pointer-2': MousePointer2,
  music: Music,
  network: Network,
  'panel-left': PanelLeft,
  'panel-right': PanelRight,
  pause: Pause,
  'picture-in-picture-2': PictureInPicture2,
  power: Power,
  radio: Radio,
  'rotate-ccw': RotateCcw,
  save: Save,
  server: Server,
  'share-2': Share2,
  'shield-check': ShieldCheck,
  signal: Signal,
  'sliders-horizontal': SlidersHorizontal,
  smartphone: Smartphone,
  sparkles: Sparkles,
  square: Square,
  star: Star,
  sun: Sun,
  tag: Tag,
  'thumbs-up': ThumbsUp,
  unlink: Unlink,
  unlock: Unlock,
  'user-check': UserCheck,
  'user-x': UserX,
  'volume-1': Volume1,
  zap: Zap,
  'zoom-in': ZoomIn,
  'zoom-out': ZoomOut,
  expand: Expand,
  shrink: Shrink,
  move: Move,
  languages: Languages,
  bug: Bug,
  wrench: Wrench,
  rocket: Rocket,
  'party-popper': PartyPopper,
  angry: Angry,
  frown: Frown,
  laugh: Laugh,
  meh: Meh,
  'loader-circle': LoaderCircle,
  'signal-weak': SignalWeak,
  'signal-lost': SignalLost,
  unplug: Unplug,
  'mic-alert': MicAlert,
} as const satisfies Record<string, LucideIcon>;

export type IconName = keyof typeof ICONS;

/** Every icon name, for the workbench and for tests. */
export const ICON_NAMES = Object.keys(ICONS) as IconName[];

/** The four sizes of the brandbook, in px: inside tags, small buttons, regular, call bar. */
const SIZES = { 'xs': 13, 'sm': 15, 'md': 18, 'lg': 20 } as const;

export type IconSize = keyof typeof SIZES;

interface IconProps {
  name: IconName;
  size?: IconSize;
  className?: string;
  /**
   * Accessible name for an icon that stands alone as content. Omit it for an
   * icon inside a labelled control: the icon is then hidden from assistive
   * technology and the control's own label speaks.
   */
  label?: string;
}

export function Icon({ name, size = 'md', className, label }: IconProps) {
  const Glyph = ICONS[name];
  const px = SIZES[size];
  return (
    <Glyph
      width={px}
      height={px}
      strokeWidth={1.75}
      absoluteStrokeWidth={false}
      className={className ? `flex-shrink-0 ${className}` : 'flex-shrink-0'}
      {...(label ? { role: 'img', 'aria-label': label } : { 'aria-hidden': true })}
    />
  );
}
