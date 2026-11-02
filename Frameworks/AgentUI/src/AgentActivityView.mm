#import "AgentActivityView.h"
#import <QuartzCore/QuartzCore.h>

static CGFloat const kDotSize            = 7;
static NSTimeInterval const kBlinkPeriod = 1.2; // seconds from bright to dim

static NSString* FormatTokens (double count)
{
	if(count >= 1e6)
		return [NSString stringWithFormat:@"%.1fM", count / 1e6];
	if(count >= 1e3)
		return [NSString stringWithFormat:@"%.1fk", count / 1e3];
	return [NSString stringWithFormat:@"%.0f", count];
}

@interface AgentActivityView ()
{
	NSView* _dot;
	NSTextField* _label;
	NSDate* _startDate;
	NSTimeInterval _elapsed; // of the finished turn
	NSTimer* _timer;
}
@end

@implementation AgentActivityView
+ (NSString*)stringFromTokens:(double)count
{
	return FormatTokens(count);
}

+ (NSString*)stringFromTimeInterval:(NSTimeInterval)interval
{
	NSUInteger seconds = (NSUInteger)MAX(0, interval);
	if(seconds >= 3600)
		return [NSString stringWithFormat:@"%lu:%02lu:%02lu", seconds / 3600, seconds / 60 % 60, seconds % 60];
	return [NSString stringWithFormat:@"%lu:%02lu", seconds / 60, seconds % 60];
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if(self = [super initWithFrame:frame])
	{
		_dot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kDotSize, kDotSize)];
		_dot.wantsLayer = YES;
		_dot.layer.cornerRadius = kDotSize / 2;

		_label = [NSTextField labelWithString:@""];
		_label.font          = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
		_label.textColor     = NSColor.secondaryLabelColor;
		_label.lineBreakMode = NSLineBreakByTruncatingMiddle;
		[_label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

		for(NSView* view in @[ _dot, _label ])
		{
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[self addSubview:view];
		}
		[NSLayoutConstraint activateConstraints:@[
			[_dot.widthAnchor constraintEqualToConstant:kDotSize],
			[_dot.heightAnchor constraintEqualToConstant:kDotSize],
			[_dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
			[_dot.centerYAnchor constraintEqualToAnchor:_label.centerYAnchor],
			[_label.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:6],
			[_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-8],
			[_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
			[_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-3],
		]];
		_dot.hidden = YES;
	}
	return self;
}

- (void)dealloc
{
	[_timer invalidate];
}

- (void)setActive:(BOOL)flag
{
	if(_active == flag)
		return;
	_active = flag;
	if(!flag)
		_elapsed = -_startDate.timeIntervalSinceNow;

	[_timer invalidate];
	_timer = nil;
	if(flag)
	{
		_startDate = [NSDate date];
		_toolCalls = 0;
		_tokens    = 0;
		_activity  = nil;
		_waiting   = NO;
		_outcome   = nil;

		__weak AgentActivityView* weakSelf = self;
		_timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer*){ [weakSelf update]; }];
		_timer.tolerance = 0.2;
		[NSRunLoop.currentRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
	}
	[self update];
}

- (void)clear
{
	self.active = NO;
	_startDate = nil;
	_toolCalls = 0;
	_tokens    = 0;
	_outcome   = nil;
	[self update];
}

- (void)setOutcome:(NSString*)outcome { _outcome = outcome; [self update]; }
- (void)setWaiting:(BOOL)flag   { _waiting = flag;   [self update]; }
- (void)setActivity:(NSString*)activity { _activity = activity; [self update]; }
- (void)setToolCalls:(NSUInteger)count  { _toolCalls = count;   [self update]; }
- (void)setTokens:(double)tokens        { _tokens = tokens;     [self update]; }

- (NSString*)statusText
{
	if(!_startDate)
		return @"";

	NSMutableArray<NSString*>* parts = [NSMutableArray array];
	if(_active)
		[parts addObject:_waiting ? @"Waiting for your approval" : (_activity.length ? _activity : @"Working")];
	else	[parts addObject:_outcome ?: @"Done"];
	[parts addObject:[AgentActivityView stringFromTimeInterval:_active ? -_startDate.timeIntervalSinceNow : _elapsed]];
	if(_toolCalls)
		[parts addObject:[NSString stringWithFormat:@"%lu tool call%@", _toolCalls, _toolCalls == 1 ? @"" : @"s"]];
	if(_tokens > 0)
		[parts addObject:[NSString stringWithFormat:@"+%@ tokens", FormatTokens(_tokens)]];
	return [parts componentsJoinedByString:@" · "];
}

- (void)update
{
	_label.stringValue = self.statusText;
	_label.toolTip     = _active ? _activity : nil;
	_dot.hidden        = !_startDate;
	[self updateDot];
}

- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	[self updateDot];
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	[self updateDot]; // layers lose their animations when taken out of a window
}

- (void)updateDot
{
	__block CGColorRef color;
	[self.effectiveAppearance performAsCurrentDrawingAppearance:^{
		NSColor* working = _waiting ? NSColor.systemOrangeColor : NSColor.controlAccentColor;
		NSColor* ended   = _outcome ? NSColor.secondaryLabelColor : NSColor.systemGreenColor;
		color = (_active ? working : ended).CGColor;
	}];
	_dot.layer.backgroundColor = color;

	BOOL blink = _active && !_waiting && self.window && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
	if(blink && ![_dot.layer animationForKey:@"blink"])
	{
		CABasicAnimation* animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
		animation.fromValue      = @1.0;
		animation.toValue        = @0.2;
		animation.duration       = kBlinkPeriod;
		animation.autoreverses   = YES;
		animation.repeatCount    = HUGE_VALF;
		animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
		[_dot.layer addAnimation:animation forKey:@"blink"];
	}
	else if(!blink)
	{
		[_dot.layer removeAnimationForKey:@"blink"];
	}
}
@end
