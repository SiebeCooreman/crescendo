#import <AppKit/AppKit.h>

static NSPoint polar(NSPoint c, CGFloat r, CGFloat deg) {
  CGFloat a = deg * M_PI / 180;
  return NSMakePoint(c.x + r * cos(a), c.y + r * sin(a));
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];

    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(100, 100, 824, 824) xRadius:185 yRadius:185];
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.16 green:0.17 blue:0.24 alpha:1]
                                   endingColor:[NSColor colorWithSRGBRed:0.04 green:0.05 blue:0.08 alpha:1]] drawInBezierPath:tile angle:-90];

    NSPoint c = NSMakePoint(512, 500);
    NSColor *amber = [NSColor colorWithSRGBRed:1.00 green:0.74 blue:0.30 alpha:1];
    NSColor *coral = [NSColor colorWithSRGBRed:1.00 green:0.34 blue:0.36 alpha:1];
    const int steps = 16, lit = 11;
    for (int i = 0; i < steps; i++) {
      CGFloat deg = 225 - i * 270.0 / (steps - 1);
      BOOL on = i < lit;
      NSBezierPath *tick = [NSBezierPath bezierPath];
      [tick moveToPoint:polar(c, 268, deg)];
      [tick lineToPoint:polar(c, on ? 300 + i * 4.5 : 300, deg)];
      tick.lineWidth = 24;
      tick.lineCapStyle = NSLineCapStyleRound;
      [NSGraphicsContext saveGraphicsState];
      if (on) {
        NSColor *col = [amber blendedColorWithFraction:(CGFloat)i / (lit - 1) ofColor:coral];
        NSShadow *glow = [NSShadow new];
        glow.shadowColor = [col colorWithAlphaComponent:0.8];
        glow.shadowBlurRadius = 28;
        [glow set];
        [col setStroke];
      } else {
        [[NSColor colorWithWhite:1 alpha:0.13] setStroke];
      }
      [tick stroke];
      [NSGraphicsContext restoreGraphicsState];
    }

    NSBezierPath *knob = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 200, c.y - 200, 400, 400)];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *drop = [NSShadow new];
    drop.shadowColor = [NSColor colorWithWhite:0 alpha:0.7];
    drop.shadowBlurRadius = 40;
    drop.shadowOffset = NSMakeSize(0, -18);
    [drop set];
    [[NSColor blackColor] setFill];
    [knob fill];
    [NSGraphicsContext restoreGraphicsState];
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.36 green:0.38 blue:0.46 alpha:1]
                                   endingColor:[NSColor colorWithSRGBRed:0.12 green:0.13 blue:0.18 alpha:1]] drawInBezierPath:knob angle:-90];
    NSBezierPath *rim = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 198, c.y - 198, 396, 396)];
    rim.lineWidth = 4;
    [[NSColor colorWithWhite:1 alpha:0.18] setStroke];
    [rim stroke];

    CGFloat pointer = 225 - (lit - 1) * 270.0 / (steps - 1);
    NSBezierPath *line = [NSBezierPath bezierPath];
    [line moveToPoint:polar(c, 95, pointer)];
    [line lineToPoint:polar(c, 165, pointer)];
    line.lineWidth = 26;
    line.lineCapStyle = NSLineCapStyleRound;
    [[NSColor colorWithWhite:1 alpha:0.95] setStroke];
    [line stroke];

    [NSGraphicsContext setCurrentContext:nil];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
  }
  return 0;
}
