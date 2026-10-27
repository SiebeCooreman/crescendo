#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import <IOKit/usb/IOUSBLib.h>
#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/ServiceManagement.h>

// Protocol from github.com/baakhoff/BiD docs/PROTOCOL.md: monitor section is unit 0x36,
// volume selector 0x12 (int16, 1/256 dB, 0x8000 = off), mute selector 0x04 (1 byte).
static const int kSteps = 16;
static const int kFloorDb = -60;
static const int kCeilingDb = 0;
static const SInt16 kOff = INT16_MIN;

static NSString *const kSavedVolume = @"volume";

static IOUSBDeviceInterface **dev;
static UInt16 iface;
static CFMachPortRef tap;
static BOOL restoring;

static CFMutableDictionaryRef deviceMatch(void) {
  CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
  int vid = 0x2708, pid = 0x0008;
  CFDictionarySetValue(match, CFSTR(kUSBVendorID), CFNumberCreate(NULL, kCFNumberIntType, &vid));
  CFDictionarySetValue(match, CFSTR(kUSBProductID), CFNumberCreate(NULL, kCFNumberIntType, &pid));
  return match;
}

static BOOL connectDevice(void) {
  if (dev) return YES;
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, deviceMatch());
  if (!svc) return NO;
  IOCFPlugInInterface **plug;
  SInt32 score;
  kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
  IOObjectRelease(svc);
  if (kr) return NO;
  (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
  IODestroyPlugInInterface(plug);
  if (!dev) return NO;

  // The audio interfaces belong to macOS's driver; the spare DFU/vendor interface takes the same requests.
  IOUSBFindInterfaceRequest any = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
  io_iterator_t it;
  (*dev)->CreateInterfaceIterator(dev, &any, &it);
  io_service_t i;
  iface = 0;
  while ((i = IOIteratorNext(it))) {
    NSNumber *cls = CFBridgingRelease(IORegistryEntryCreateCFProperty(i, CFSTR("bInterfaceClass"), NULL, 0));
    NSNumber *num = CFBridgingRelease(IORegistryEntryCreateCFProperty(i, CFSTR("bInterfaceNumber"), NULL, 0));
    IOObjectRelease(i);
    if (cls.intValue == 0xfe || cls.intValue == 0xff) iface = num.unsignedShortValue;
  }
  IOObjectRelease(it);
  return YES;
}

static IOReturn request(UInt8 type, UInt16 wValue, void *buf, UInt16 len) {
  IOUSBDevRequest r = {type, 0x01, wValue, (UInt16)(0x3600 | iface), len, buf, 0};
  IOReturn e = (*dev)->DeviceRequest(dev, &r);
  if (e) {
    // Most likely unplugged; reconnect on the next key press.
    (*dev)->Release(dev);
    dev = NULL;
  }
  return e;
}

static BOOL readState(SInt16 *v, UInt8 *muted) {
  UInt8 b[2] = {0};
  if (!connectDevice() || request(0xa1, 0x1200, b, 2)) return NO;
  *v = (SInt16)(b[0] | b[1] << 8);
  return connectDevice() && !request(0xa1, 0x0400, muted, 1);
}

static void writeVolume(SInt16 v) {
  UInt8 b[2] = {v & 0xff, (v >> 8) & 0xff};
  if (!request(0x21, 0x1200, b, 2)) [NSUserDefaults.standardUserDefaults setInteger:v forKey:kSavedVolume];
}

// The iD14 comes back from a reconnect at its own startup level, possibly corrected a moment later by
// the iD app, so the saved level is checked and re-applied a few times.
static void restoreVolume(int attempt) {
  NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:kSavedVolume];
  SInt16 v;
  UInt8 m = 0;
  if (saved && readState(&v, &m) && v != saved.shortValue) writeVolume(saved.shortValue);
  if (saved && attempt < 3) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ restoreVolume(attempt + 1); });
  } else {
    restoring = NO;
  }
}

static void onArrival(void *ctx, io_iterator_t it) {
  io_service_t s;
  BOOL arrived = NO;
  while ((s = IOIteratorNext(it))) {
    IOObjectRelease(s);
    arrived = YES;
  }
  if (!arrived) return;
  if (dev) {
    (*dev)->Release(dev);
    dev = NULL;
  }
  restoring = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ restoreVolume(1); });
}

// Snaps to the next of 16 equal steps, so a knob position between steps still moves one step.
static SInt16 nextLevel(SInt16 v, int dir) {
  double x = v == kOff ? 0 : (v / 256.0 - kFloorDb) * kSteps / (kCeilingDb - kFloorDb);
  int n = dir > 0 ? MAX((int)floor(x) + 1, 1) : (int)ceil(x) - 1;
  n = MIN(MAX(n, 0), kSteps);
  return n == 0 ? kOff : (SInt16)lround((kFloorDb + n * (kCeilingDb - kFloorDb) / (double)kSteps) * 256);
}

static NSPanel *hud;
static NSImageView *hudIcon;
static CALayer *hudFill;
static int hudShown;
static const CGFloat kBarWidth = 176, kBarHeight = 12;

static void makeHud(void) {
  hud = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 240, 48)
                                   styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                     backing:NSBackingStoreBuffered
                                       defer:NO];
  hud.level = NSStatusWindowLevel;
  hud.opaque = NO;
  hud.backgroundColor = NSColor.clearColor;
  hud.ignoresMouseEvents = YES;
  hud.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
  NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:hud.contentView.bounds];
  bg.material = NSVisualEffectMaterialHUDWindow;
  bg.state = NSVisualEffectStateActive;
  bg.wantsLayer = YES;
  bg.layer.cornerRadius = 14;
  hud.contentView = bg;
  hudIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 12, 24, 24)];
  // A plain layer instead of NSProgressIndicator, whose built-in fill animation is slow and can't be tuned.
  NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(48, 18, kBarWidth, kBarHeight)];
  bar.wantsLayer = YES;
  bar.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.2].CGColor;
  bar.layer.cornerRadius = kBarHeight / 2;
  bar.layer.masksToBounds = YES;
  hudFill = [CALayer layer];
  hudFill.backgroundColor = NSColor.controlAccentColor.CGColor;
  hudFill.frame = CGRectMake(0, 0, 0, kBarHeight);
  [bar.layer addSublayer:hudFill];
  [bg addSubview:hudIcon];
  [bg addSubview:bar];
}

static void showHud(SInt16 v, BOOL muted) {
  BOOL silent = muted || v == kOff;
  hudIcon.image = [NSImage imageWithSystemSymbolName:silent ? @"speaker.slash.fill" : @"speaker.wave.2.fill" accessibilityDescription:nil];
  CGFloat fraction = v == kOff ? 0 : (v / 256.0 - kFloorDb) / (kCeilingDb - kFloorDb);
  [CATransaction begin];
  [CATransaction setAnimationDuration:0.06];
  hudFill.frame = CGRectMake(0, 0, kBarWidth * fraction, kBarHeight);
  [CATransaction commit];
  NSRect screen = NSScreen.mainScreen.visibleFrame;
  [hud setFrameOrigin:NSMakePoint(NSMaxX(screen) - 252, NSMaxY(screen) - 60)];
  [hud orderFrontRegardless];
  // Draw now, before the USB write blocks the run loop.
  [hud displayIfNeeded];
  [CATransaction flush];
  int shown = ++hudShown;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    if (shown == hudShown) [hud orderOut:nil];
  });
}

static BOOL iD14IsDefaultOutput(void) {
  AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioDeviceID d;
  UInt32 n = sizeof d;
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &n, &d)) return NO;
  a.mSelector = kAudioObjectPropertyName;
  CFStringRef name = NULL;
  n = sizeof name;
  if (AudioObjectGetPropertyData(d, &a, 0, NULL, &n, &name)) return NO;
  return [CFBridgingRelease(name) hasPrefix:@"Audient iD14"];
}

static CGEventRef onEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ctx) {
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    CGEventTapEnable(tap, true);
    return e;
  }
  NSEvent *ev = [NSEvent eventWithCGEvent:e];
  if (ev.subtype != 8) return e;
  int key = (int)((ev.data1 & 0xffff0000) >> 16);
  BOOL down = ((ev.data1 & 0xff00) >> 8) == 0x0a;
  if (key != NX_KEYTYPE_SOUND_UP && key != NX_KEYTYPE_SOUND_DOWN && key != NX_KEYTYPE_MUTE) return e;
  if (!iD14IsDefaultOutput() || !connectDevice()) return e;
  SInt16 v;
  UInt8 m = 0;
  // Read before every write: the knob may have moved since the last press.
  if (!down || !readState(&v, &m)) return NULL;
  if (key == NX_KEYTYPE_MUTE) {
    m = !m;
    showHud(v, m);
    request(0x21, 0x0400, &m, 1);
  } else {
    SInt16 next = nextLevel(v, key == NX_KEYTYPE_SOUND_UP ? 1 : -1);
    showHud(next, m);
    writeVolume(next);
  }
  return NULL;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1], "--read")) {
      SInt16 v;
      UInt8 m = 0;
      if (!readState(&v, &m)) { puts("iD14 not found or read failed"); return 1; }
      printf("interface %d  volume %.2f dB (raw 0x%04x)  mute %d\n", iface, v / 256.0, (UInt16)v, m);
      return 0;
    }
    if (SMAppService.mainAppService.status != SMAppServiceStatusEnabled) [SMAppService.mainAppService registerAndReturnError:nil];
    // The tap only succeeds once Accessibility is granted; wait for it instead of quitting.
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES});
    while (!(tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                    CGEventMaskBit(NSEventTypeSystemDefined), onEvent, NULL))) {
      sleep(2);
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(NULL, tap, 0), kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyAccessory;
    makeHud();

    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopCommonModes);
    io_iterator_t arrivals;
    IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, deviceMatch(), onArrival, NULL, &arrivals);
    onArrival(NULL, arrivals);

    // Polling catches knob turns too. Never saved while restoring: a reconnected iD14 reports its
    // startup level until restoreVolume has put the remembered one back.
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
      SInt16 v;
      UInt8 m = 0;
      if (!restoring && dev && readState(&v, &m)) [NSUserDefaults.standardUserDefaults setInteger:v forKey:kSavedVolume];
    }];
    [NSApp run];
  }
  return 0;
}
