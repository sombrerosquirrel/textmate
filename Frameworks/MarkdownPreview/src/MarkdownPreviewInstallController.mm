#import "MarkdownPreviewInstallController.h"
#import "MarkdownPreviewCmark.h"
#import <AgentClient/AgentEnvironment.h>
#import <Preferences/Keys.h>

static NSString* BrewPath (NSDictionary<NSString*, NSString*>* environment)
{
	if(NSString* path = [AgentEnvironment executablePathForCommand:@"brew" environment:environment])
		return path;
	return [AgentEnvironment executablePathForCommand:@"brew" environment:@{ @"PATH": @"/opt/homebrew/bin:/usr/local/bin" }];
}

@interface MarkdownPreviewInstallController ()
{
	NSDictionary<NSString*, NSString*>* _environment;
	NSString* _brewPath;
	void(^_completion)(NSString*);
	MarkdownPreviewInstallController* _retainedSelf; // while the sheet is up

	NSTextField* _statusLabel;
	NSProgressIndicator* _spinner;
	NSScrollView* _logScrollView;
	NSTextView* _logTextView;
	NSButton* _installButton;
	NSButton* _locateButton;

	NSTask* _task;
}
@end

@implementation MarkdownPreviewInstallController
- (instancetype)init
{
	NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 200) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	return [super initWithWindow:panel];
}

- (void)setupViews
{
	NSTextField* titleLabel = [NSTextField labelWithString:@"Install cmark-gfm?"];
	titleLabel.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];

	NSString* message = _brewPath
		? @"The GitHub renderer uses cmark-gfm, GitHub’s Markdown parser, which isn’t installed. TextMate can install it with Homebrew (brew install cmark-gfm), or you can locate a copy you’ve installed."
		: @"The GitHub renderer uses cmark-gfm, GitHub’s Markdown parser, which isn’t installed. Install it with Homebrew (https://brew.sh) by running “brew install cmark-gfm” in Terminal, or build it from https://github.com/github/cmark-gfm, then click Locate… to choose it.";
	NSTextField* messageLabel = [NSTextField wrappingLabelWithString:message];
	messageLabel.selectable = YES;
	[messageLabel.widthAnchor constraintEqualToConstant:480].active = YES;

	_logTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 160)];
	_logTextView.editable = NO;
	_logTextView.font     = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
	_logTextView.autoresizingMask = NSViewWidthSizable;
	_logTextView.textContainerInset = NSMakeSize(4, 4);

	_logScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 160)];
	_logScrollView.hasVerticalScroller = YES;
	_logScrollView.borderType = NSBezelBorder;
	_logScrollView.documentView = _logTextView;
	_logScrollView.hidden = YES;
	[_logScrollView.widthAnchor constraintEqualToConstant:480].active = YES;
	[_logScrollView.heightAnchor constraintEqualToConstant:160].active = YES;

	_spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
	_spinner.style = NSProgressIndicatorStyleSpinning;
	_spinner.controlSize = NSControlSizeSmall;
	_spinner.displayedWhenStopped = NO;

	_statusLabel = [NSTextField labelWithString:@""];
	_statusLabel.textColor = NSColor.secondaryLabelColor;

	NSStackView* statusStack = [NSStackView stackViewWithViews:@[ _spinner, _statusLabel ]];
	statusStack.spacing = 6;

	_locateButton  = [NSButton buttonWithTitle:@"Locate…" target:self action:@selector(locate:)];
	_installButton = [NSButton buttonWithTitle:@"Install with Homebrew" target:self action:@selector(install:)];
	NSButton* cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
	cancelButton.keyEquivalent = @"\e";
	if(_brewPath)
		_installButton.keyEquivalent = @"\r";
	else
		_installButton.hidden = YES;

	NSView* spacer = [[NSView alloc] initWithFrame:NSZeroRect];
	[spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* buttons = [NSStackView stackViewWithViews:@[ _locateButton, spacer, cancelButton, _installButton ]];
	buttons.detachesHiddenViews = YES;
	[buttons.widthAnchor constraintEqualToConstant:480].active = YES;

	NSStackView* stack = [NSStackView stackViewWithViews:@[ titleLabel, messageLabel, _logScrollView, statusStack, buttons ]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment   = NSLayoutAttributeLeading;
	stack.spacing     = 12;
	stack.detachesHiddenViews = YES;
	stack.edgeInsets  = NSEdgeInsetsMake(20, 20, 20, 20);
	[stack setCustomSpacing:6 afterView:titleLabel];

	self.window.contentView = stack;
}

- (void)beginSheetModalForWindow:(NSWindow*)window environment:(NSDictionary<NSString*, NSString*>*)environment completionHandler:(void(^)(NSString* cmarkPath))completion
{
	_environment  = environment;
	_brewPath     = BrewPath(environment);
	_completion   = completion;
	_retainedSelf = self;

	[self setupViews];
	[window beginSheet:self.window completionHandler:nil];
}

- (void)finishWithPath:(NSString*)path
{
	[_task terminate];
	_task = nil;

	[self.window.sheetParent endSheet:self.window];
	if(_completion)
		_completion(path);
	_completion   = nil;
	_retainedSelf = nil;
}

- (void)cancel:(id)sender
{
	[self finishWithPath:nil];
}

// ===========
// = Locate… =
// ===========

- (void)locate:(id)sender
{
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.message = @"Choose the cmark-gfm program.";
	panel.prompt  = @"Choose";
	panel.treatsFilePackagesAsDirectories = YES;
	panel.showsHiddenFiles = YES;
	panel.directoryURL = [NSURL fileURLWithPath:@"/opt/homebrew/bin" isDirectory:YES];

	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
		if(response != NSModalResponseOK)
			return;

		NSString* path = panel.URL.path;
		if(![NSFileManager.defaultManager isExecutableFileAtPath:path])
		{
			_statusLabel.stringValue = [NSString stringWithFormat:@"“%@” isn’t a program.", path.lastPathComponent];
			return;
		}
		[NSUserDefaults.standardUserDefaults setObject:path forKey:kUserDefaultsMarkdownPreviewCmarkPathKey];
		[self finishWithPath:path];
	}];
}

// ===========
// = Install =
// ===========

- (void)appendToLog:(NSString*)text
{
	NSDictionary* attributes = @{ NSFontAttributeName: _logTextView.font, NSForegroundColorAttributeName: NSColor.textColor };
	[_logTextView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
	[_logTextView scrollToEndOfDocument:nil];
}

- (void)install:(id)sender
{
	NSMutableDictionary* environment = [_environment mutableCopy];
	environment[@"NONINTERACTIVE"]        = @"1";
	environment[@"HOMEBREW_NO_ENV_HINTS"] = @"1";
	environment[@"HOMEBREW_NO_COLOR"]     = @"1";

	NSTask* task = [[NSTask alloc] init];
	task.executableURL  = [NSURL fileURLWithPath:_brewPath];
	task.arguments      = @[ @"install", @"cmark-gfm" ];
	task.environment    = environment;
	task.standardInput  = [NSFileHandle fileHandleWithNullDevice];

	NSPipe* outputPipe = [NSPipe pipe];
	task.standardOutput = outputPipe;
	task.standardError  = outputPipe;

	__weak MarkdownPreviewInstallController* weakSelf = self;
	outputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* handle){
		NSData* data = handle.availableData;
		if(data.length == 0)
		{
			handle.readabilityHandler = nil;
			return;
		}
		NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf appendToLog:text];
		});
	};

	task.terminationHandler = ^(NSTask* task){
		int status = task.terminationStatus;
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf installDidFinish:task status:status];
		});
	};

	NSError* error;
	[self appendToLog:[NSString stringWithFormat:@"$ %@ install cmark-gfm\n", _brewPath]];
	if(![task launchAndReturnError:&error])
	{
		_statusLabel.stringValue = error.localizedDescription;
		return;
	}

	_task = task;
	_logScrollView.hidden    = NO;
	_installButton.enabled   = NO;
	_locateButton.enabled    = NO;
	_statusLabel.stringValue = @"Installing…";
	[_spinner startAnimation:nil];
}

- (void)installDidFinish:(NSTask*)task status:(int)status
{
	if(task != _task)
		return; // cancelled
	_task = nil;
	[_spinner stopAnimation:nil];

	NSString* path = status == 0 ? [MarkdownPreviewCmark executablePathInEnvironment:_environment] : nil;
	if(path)
		return [self finishWithPath:path];

	_statusLabel.stringValue = status == 0 ? @"Homebrew finished, but cmark-gfm wasn’t found." : [NSString stringWithFormat:@"Installation failed (exit status %d).", status];
	_installButton.title     = @"Try Again";
	_installButton.enabled   = YES;
	_locateButton.enabled    = YES;
}
@end
