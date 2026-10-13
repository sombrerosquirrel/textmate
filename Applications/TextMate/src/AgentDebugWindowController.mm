#import "AgentDebugWindowController.h"
#import <AgentClient/AgentSession.h>
#import <AgentClient/AgentEnvironment.h>
#import <DocumentWindow/DocumentWindowController.h>

static NSArray<NSDictionary*>* KnownAgents ()
{
	return @[
		@{ @"name": @"GitHub Copilot", @"command": @"copilot", @"arguments": @[ @"--acp" ] },
		@{ @"name": @"Claude Code",    @"command": @"npx",     @"arguments": @[ @"-y", @"@agentclientprotocol/claude-agent-acp" ] },
	];
}

static NSString* FrontmostProjectPath ()
{
	for(NSWindow* window in NSApp.orderedWindows)
	{
		if([window.delegate isKindOfClass:[DocumentWindowController class]])
		{
			if(NSString* path = ((DocumentWindowController*)window.delegate).projectPath)
				return path;
		}
	}
	return NSHomeDirectory();
}

static NSString* StateName (AgentSessionState state)
{
	switch(state)
	{
		case AgentSessionStateIdle:       return @"idle";
		case AgentSessionStateStarting:   return @"starting";
		case AgentSessionStateReady:      return @"ready";
		case AgentSessionStatePrompting:  return @"working";
		case AgentSessionStateFailed:     return @"failed";
		case AgentSessionStateTerminated: return @"terminated";
	}
	return @"unknown";
}

@interface AgentDebugWindowController () <NSWindowDelegate, AgentSessionDelegate>
{
	NSPopUpButton* _agentPopUp;
	NSTextField* _promptField;
	NSButton* _sendButton;
	NSButton* _stopButton;
	NSTextField* _statusField;
	NSTextView* _transcriptView;

	AgentSession* _session;
	NSDictionary* _sessionAgent;
	NSString* _lastUpdateKind;
}
@end

@implementation AgentDebugWindowController
+ (void)showWindow:(id)sender
{
	static AgentDebugWindowController* sharedInstance = [[self alloc] init];
	[sharedInstance showWindow:sender];
	[sharedInstance.window makeFirstResponder:sharedInstance->_promptField];
}

- (instancetype)init
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 520) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
	window.title = @"Agent (Debug)";
	window.releasedWhenClosed = NO;
	window.frameAutosaveName = @"Agent Debug Window";
	[window center];

	if(self = [super initWithWindow:window])
	{
		window.delegate = self;

		_agentPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		for(NSDictionary* agent in KnownAgents())
			[_agentPopUp addItemWithTitle:agent[@"name"]];

		_promptField = [NSTextField textFieldWithString:@""];
		_promptField.placeholderString = @"Ask the agent…";
		_promptField.target = self;
		_promptField.action = @selector(send:);

		_sendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(send:)];
		_stopButton = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stop:)];
		_stopButton.enabled = NO;

		_statusField = [NSTextField labelWithString:@"No session"];
		_statusField.textColor = NSColor.secondaryLabelColor;

		NSScrollView* scrollView = [NSTextView scrollableTextView];
		_transcriptView = scrollView.documentView;
		_transcriptView.editable = NO;
		_transcriptView.textContainerInset = NSMakeSize(6, 6);

		NSStackView* controls = [NSStackView stackViewWithViews:@[ _agentPopUp, _promptField, _sendButton, _stopButton ]];
		[_promptField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

		NSStackView* stack = [NSStackView stackViewWithViews:@[ controls, scrollView, _statusField ]];
		stack.orientation = NSUserInterfaceLayoutOrientationVertical;
		stack.alignment   = NSLayoutAttributeLeading;
		stack.edgeInsets  = NSEdgeInsetsMake(12, 12, 12, 12);
		stack.translatesAutoresizingMaskIntoConstraints = NO;

		[window.contentView addSubview:stack];
		[NSLayoutConstraint activateConstraints:@[
			[stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],
			[stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],
			[stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
			[stack.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
			[controls.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-24],
			[scrollView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-24],
		]];
	}
	return self;
}

- (void)windowWillClose:(NSNotification*)aNotification
{
	[_session close];
	_session = nil;
}

// ==============
// = Transcript =
// ==============

- (void)append:(NSString*)text color:(NSColor*)color
{
	NSDictionary* attributes = @{
		NSFontAttributeName:            [NSFont userFixedPitchFontOfSize:12],
		NSForegroundColorAttributeName: color ?: NSColor.textColor,
	};
	[_transcriptView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
	[_transcriptView scrollToEndOfDocument:self];
}

- (void)appendLine:(NSString*)text color:(NSColor*)color
{
	NSString* existing = _transcriptView.string;
	if(existing.length && ![existing hasSuffix:@"\n"])
		text = [@"\n" stringByAppendingString:text];
	[self append:[text stringByAppendingString:@"\n"] color:color];
	_lastUpdateKind = nil;
}

- (void)updateControls
{
	BOOL working = _session.state == AgentSessionStateStarting || _session.state == AgentSessionStatePrompting;
	_sendButton.enabled  = !working;
	_promptField.enabled = !working;
	_agentPopUp.enabled  = !working;
	_stopButton.enabled  = _session.state == AgentSessionStatePrompting;

	NSString* agentName = _session.agentInfo[@"title"] ?: _sessionAgent[@"name"];
	_statusField.stringValue = _session ? [NSString stringWithFormat:@"%@ — %@ — %@", agentName, StateName(_session.state), _session.workingDirectory] : @"No session";
}

// ===========
// = Actions =
// ===========

- (void)send:(id)sender
{
	NSString* text = _promptField.stringValue;
	if(!text.length || _session.state == AgentSessionStateStarting || _session.state == AgentSessionStatePrompting)
		return;
	_promptField.stringValue = @"";

	NSDictionary* agent = KnownAgents()[_agentPopUp.indexOfSelectedItem];
	[self appendLine:[NSString stringWithFormat:@"> %@", text] color:NSColor.systemBlueColor];

	if(_session && _session.state == AgentSessionStateReady && [_sessionAgent isEqual:agent])
		return [self sendPrompt:text];

	[_session close];
	_session      = nil;
	_sessionAgent = agent;

	NSString* projectPath = FrontmostProjectPath();
	[self appendLine:[NSString stringWithFormat:@"Starting %@ in %@…", agent[@"name"], projectPath] color:NSColor.secondaryLabelColor];

	[AgentEnvironment loadLoginShellEnvironmentWithCompletion:^(NSDictionary<NSString*, NSString*>* environment){
		NSString* executable = [AgentEnvironment executablePathForCommand:agent[@"command"] environment:environment];
		if(!executable)
		{
			[self appendLine:[NSString stringWithFormat:@"Unable to find “%@” on PATH: %@", agent[@"command"], environment[@"PATH"]] color:NSColor.systemRedColor];
			return;
		}

		AgentConnection* connection = [[AgentConnection alloc] initWithExecutable:executable arguments:agent[@"arguments"] environment:environment workingDirectory:projectPath];
		_session = [[AgentSession alloc] initWithConnection:connection workingDirectory:projectPath];
		_session.delegate = self;

		AgentSession* session = _session;
		[session startWithCompletion:^(NSError* error){
			if(error)
				return [self appendLine:[NSString stringWithFormat:@"Failed to start: %@", error.localizedDescription] color:NSColor.systemRedColor];
			if(session == _session)
				[self sendPrompt:text];
		}];
		[self updateControls];
	}];
}

- (void)sendPrompt:(NSString*)text
{
	[_session sendPrompt:@[ @{ @"type": @"text", @"text": text } ] completion:^(NSString* stopReason, NSError* error){
		if(error)
				[self appendLine:[NSString stringWithFormat:@"Error: %@", error.localizedDescription] color:NSColor.systemRedColor];
		else	[self appendLine:[NSString stringWithFormat:@"[%@]", stopReason] color:NSColor.secondaryLabelColor];
	}];
}

- (void)stop:(id)sender
{
	[_session cancel];
}

// ========================
// = AgentSessionDelegate =
// ========================

- (void)agentSessionDidChangeState:(AgentSession*)session
{
	if(session != _session)
		return;
	[self updateControls];
	if(session.state == AgentSessionStateFailed || session.state == AgentSessionStateTerminated)
		[self appendLine:[NSString stringWithFormat:@"Session %@%@", StateName(session.state), session.error ? [@": " stringByAppendingString:session.error.localizedDescription] : @""] color:NSColor.systemRedColor];
}

- (void)agentSession:(AgentSession*)session didReceiveUpdate:(NSDictionary*)update
{
	NSString* kind = update[@"sessionUpdate"];
	if([kind isEqualToString:@"agent_message_chunk"] || [kind isEqualToString:@"agent_thought_chunk"])
	{
		NSDictionary* content = update[@"content"];
		if(![content[@"type"] isEqualToString:@"text"])
			return;
		if(![kind isEqualToString:_lastUpdateKind])
			[self appendLine:[kind isEqualToString:@"agent_thought_chunk"] ? @"(thinking)" : @"" color:NSColor.secondaryLabelColor];
		[self append:content[@"text"] color:[kind isEqualToString:@"agent_thought_chunk"] ? NSColor.secondaryLabelColor : nil];
		_lastUpdateKind = kind;
	}
	else if([kind isEqualToString:@"tool_call"])
	{
		[self appendLine:[NSString stringWithFormat:@"▸ %@ (%@, %@)", update[@"title"], update[@"kind"] ?: @"other", update[@"status"] ?: @"pending"] color:NSColor.systemPurpleColor];
	}
	else if([kind isEqualToString:@"tool_call_update"] && update[@"status"])
	{
		[self appendLine:[NSString stringWithFormat:@"  ↳ %@ %@", update[@"toolCallId"], update[@"status"]] color:NSColor.systemPurpleColor];
	}
	else if([kind isEqualToString:@"plan"])
	{
		NSMutableArray* lines = [NSMutableArray arrayWithObject:@"Plan:"];
		for(NSDictionary* entry in update[@"entries"])
			[lines addObject:[NSString stringWithFormat:@"  [%@] %@", entry[@"status"], entry[@"content"]]];
		[self appendLine:[lines componentsJoinedByString:@"\n"] color:NSColor.systemOrangeColor];
	}
}

- (void)agentSession:(AgentSession*)session didReceiveNotification:(NSString*)method params:(id)params
{
	if([method isEqualToString:@"_auth/status_update"])
		[self appendLine:[NSString stringWithFormat:@"Signed in: %@", params[@"authStatus"][@"label"] ?: params] color:NSColor.secondaryLabelColor];
}

- (void)agentSession:(AgentSession*)session didReceiveStandardError:(NSString*)text
{
	NSLog(@"[Agent][stderr] %@", text);
}

- (void)agentSession:(AgentSession*)session didTransferMessage:(NSDictionary*)message outgoing:(BOOL)outgoing
{
	NSLog(@"[Agent] %@ %@", outgoing ? @"→" : @"←", message[@"method"] ?: [NSString stringWithFormat:@"response %@", message[@"id"]]);
}
@end
