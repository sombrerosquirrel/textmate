#import "AgentPanelViewController.h"
#import "AgentPromptView.h"
#import "AgentTranscriptView.h"
#import <AgentClient/AgentRegistry.h>
#import <OakAppKit/NSColor Additions.h>

NSString* const kUserDefaultsAgentPanelAgentKey = @"agentPanelAgent";

static NSString* FormatTokenCount (double count)
{
	if(count >= 1e6)
		return [NSString stringWithFormat:@"%.1fM", count / 1e6];
	if(count >= 1e3)
		return [NSString stringWithFormat:@"%.1fk", count / 1e3];
	return [NSString stringWithFormat:@"%.0f", count];
}

static NSString* StopReasonNotice (NSString* stopReason)
{
	if([stopReason isEqualToString:@"cancelled"])         return @"Stopped.";
	if([stopReason isEqualToString:@"max_tokens"])        return @"Stopped: the reply reached the agent’s token limit.";
	if([stopReason isEqualToString:@"max_turn_requests"]) return @"Stopped: the agent reached its step limit for one request.";
	if([stopReason isEqualToString:@"refusal"])           return @"The agent declined this request.";
	return nil;
}

// The whole panel uses the file browser’s background; only the prompt’s
// input field has a text background.
@interface AgentPanelBackgroundView : NSView
@end

@implementation AgentPanelBackgroundView
- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)rect
{
	[NSColor.tmSidebarBackgroundColor setFill];
	NSRectFill(rect);
}
@end

static NSView* Separator ()
{
	NSBox* box = [[NSBox alloc] initWithFrame:NSZeroRect];
	box.boxType = NSBoxSeparator;
	return box;
}

@interface AgentPanelViewController () <AgentSessionDelegate, AgentPromptViewDelegate, AgentTranscriptViewDelegate>
{
	AgentDescriptor* _agent;
	AgentSession* _session;
	BOOL _creatingSession;

	AgentTranscript* _transcript;
	NSString* _pendingText;                     // sent once the session is ready
	NSArray<AgentAttachment*>* _pendingAttachments;
	NSString* _usageText;

	NSPopUpButton* _agentPopUp;
	AgentTranscriptView* _transcriptView;
	AgentPromptView* _promptView;
	NSStackView* _optionsView;
	NSTextField* _statusField;
}
@end

@implementation AgentPanelViewController
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{ kUserDefaultsAgentPanelAgentKey: @"copilot" }];
}

- (instancetype)init
{
	if(self = [super initWithNibName:nil bundle:nil])
	{
		_transcript = [[AgentTranscript alloc] init];
		_agent      = [AgentRegistry agentWithIdentifier:[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsAgentPanelAgentKey]] ?: AgentRegistry.agents.firstObject;
	}
	return self;
}

- (void)dealloc
{
	[_session close];
}

- (void)loadView
{
	_agentPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_agentPopUp.controlSize = NSControlSizeSmall;
	_agentPopUp.font        = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_agentPopUp.target      = self;
	_agentPopUp.action      = @selector(agentChanged:);
	_agentPopUp.toolTip     = @"Agent";
	for(AgentDescriptor* agent in AgentRegistry.agents)
	{
		[_agentPopUp addItemWithTitle:agent.name];
		_agentPopUp.lastItem.representedObject = agent.identifier;
	}
	[_agentPopUp selectItemAtIndex:[AgentRegistry.agents indexOfObject:_agent]];

	NSButton* newChatButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"square.and.pencil" accessibilityDescription:@"New Chat"] target:self action:@selector(newChat:)];
	newChatButton.bordered = NO;
	newChatButton.toolTip  = @"New Chat";

	NSStackView* header = [NSStackView stackViewWithViews:@[ _agentPopUp, [NSView new], newChatButton ]];
	header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	header.edgeInsets  = NSEdgeInsetsMake(6, 8, 6, 8);

	NSScrollView* transcriptScrollView = [AgentTranscriptView scrollableTranscriptView];
	_transcriptView = transcriptScrollView.documentView;
	_transcriptView.transcript     = _transcript;
	_transcriptView.actionDelegate = self;

	_promptView = [[AgentPromptView alloc] initWithFrame:NSZeroRect];
	_promptView.delegate = self;

	_optionsView = [NSStackView stackViewWithViews:@[ ]];
	_optionsView.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	_optionsView.spacing     = 4;

	_statusField = [NSTextField labelWithString:@""];
	_statusField.font          = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_statusField.textColor     = NSColor.secondaryLabelColor;
	_statusField.lineBreakMode = NSLineBreakByTruncatingTail;
	[_statusField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	NSStackView* footer = [NSStackView stackViewWithViews:@[ _optionsView, [NSView new], _statusField ]];
	footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	footer.edgeInsets  = NSEdgeInsetsMake(0, 8, 6, 8);

	NSStackView* stack = [NSStackView stackViewWithViews:@[ header, Separator(), transcriptScrollView, Separator(), _promptView, footer ]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.spacing     = 0;
	// NSStackView hugs its content at a priority above the window’s “stay put”
	// priority, which would shrink the window to the panel’s minimum size
	[stack setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
	[stack setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	for(NSView* view in stack.arrangedSubviews)
		[view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
	[transcriptScrollView setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

	NSView* container = [[AgentPanelBackgroundView alloc] initWithFrame:NSMakeRect(0, 0, 380, 600)];
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
		[stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
		[stack.topAnchor constraintEqualToAnchor:container.topAnchor],
		[stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
	]];
	self.view = container;

	[self updatePlaceholders];
	[self updateStatus];
}

- (void)updatePlaceholders
{
	_transcriptView.emptyStateString = [NSString stringWithFormat:@"Ask %@ about this project.\n\nType / for the agent’s commands.\nUse + or drag files in to add context.", _agent.name];
	_promptView.placeholderString     = [NSString stringWithFormat:@"Ask %@…", _agent.name];
}

- (void)focusPrompt
{
	[self.view.window makeFirstResponder:_promptView.initialFirstResponder];
}

// ===========
// = Session =
// ===========

- (BOOL)sessionIsUsable
{
	return _session && (_session.state == AgentSessionStateStarting || _session.state == AgentSessionStateReady || _session.state == AgentSessionStatePrompting);
}

- (void)startSessionIfNeeded
{
	if(_creatingSession || [self sessionIsUsable])
		return;

	[self closeSession];
	_creatingSession = YES;
	[self updateStatus];

	AgentDescriptor* agent = _agent;
	NSString* projectPath  = [_delegate projectPathForAgentPanel:self] ?: NSHomeDirectory();
	[AgentRegistry makeSessionForAgent:agent workingDirectory:projectPath completion:^(AgentSession* session, NSError* error){
		_creatingSession = NO;
		if(agent != _agent)
			return [self startSessionIfNeeded]; // the user switched agents meanwhile

		if(error)
		{
			[self showError:error.localizedDescription];
			[self failPendingPrompt];
			[self updateStatus];
			return;
		}

		_session = session;
		_session.delegate = self;
		[session startWithCompletion:^(NSError* error){
			if(session != _session)
				return;
			if(error)
			{
				[self showError:[NSString stringWithFormat:@"%@ didn’t start: %@", agent.name, error.localizedDescription]];
				[self failPendingPrompt];
			}
			else if(_pendingText || _pendingAttachments)
			{
				[self sendPendingPrompt];
			}
			[self rebuildOptions];
			[self updateStatus];
		}];
		[self updateStatus];
	}];
}

- (void)closeSession
{
	AgentSession* session = _session;
	_session   = nil;
	_usageText = nil;
	session.delegate = nil;
	[session close];
	[self rebuildOptions];
}

- (void)shutdown
{
	[self closeSession];
}

- (void)resetConversation
{
	[self closeSession];
	[_transcript removeAllItems];
	[_transcriptView reloadData];
	_pendingText        = nil;
	_pendingAttachments = nil;
	_promptView.working = NO;
	[self updatePlaceholders];
	[self startSessionIfNeeded];
}

- (IBAction)newChat:(id)sender
{
	[self resetConversation];
	[self focusPrompt];
}

- (void)agentChanged:(NSPopUpButton*)sender
{
	AgentDescriptor* agent = [AgentRegistry agentWithIdentifier:sender.selectedItem.representedObject];
	if(!agent || agent == _agent)
		return;
	_agent = agent;
	[NSUserDefaults.standardUserDefaults setObject:agent.identifier forKey:kUserDefaultsAgentPanelAgentKey];
	[self resetConversation];
	[self focusPrompt];
}

- (void)askAboutSelection
{
	AgentAttachment* attachment = nil;
	if([_delegate respondsToSelector:@selector(selectionAttachmentForAgentPanel:)])
		attachment = [_delegate selectionAttachmentForAgentPanel:self];
	if(!attachment && [_delegate respondsToSelector:@selector(currentFileAttachmentForAgentPanel:)])
		attachment = [_delegate currentFileAttachmentForAgentPanel:self];
	if(attachment)
		[_promptView addAttachment:attachment];
	[self startSessionIfNeeded];
	[self focusPrompt];
}

// =============
// = Prompting =
// =============

- (void)showItem:(AgentTranscriptItem*)item
{
	[_transcriptView setNeedsDisplayItem:item];
}

- (void)showError:(NSString*)message
{
	[self showItem:[_transcript addError:message]];
}

- (void)showNotice:(NSString*)message
{
	[self showItem:[_transcript addNotice:message]];
}

- (void)promptViewDidSubmit:(AgentPromptView*)promptView
{
	NSString* text = promptView.text;
	NSArray<AgentAttachment*>* attachments = promptView.attachments;

	[promptView rememberPrompt:text];
	[self showItem:[_transcript addUserMessage:text attachmentNames:[attachments valueForKey:@"name"]]];
	promptView.text = @"";
	[promptView removeAllAttachments];

	_pendingText        = text;
	_pendingAttachments = attachments;
	promptView.working  = YES;

	if(_session.state == AgentSessionStateReady)
			[self sendPendingPrompt];
	else	[self startSessionIfNeeded];
	[self updateStatus];
}

- (void)sendPendingPrompt
{
	NSDictionary* promptCapabilities = _session.agentCapabilities[@"promptCapabilities"];
	NSArray* prompt = [AgentAttachment promptWithText:_pendingText attachments:_pendingAttachments promptCapabilities:promptCapabilities];
	_pendingText        = nil;
	_pendingAttachments = nil;

	AgentSession* session = _session;
	[session sendPrompt:prompt completion:^(NSString* stopReason, NSError* error){
		if(session != _session)
			return;
		_promptView.working = NO;
		if(error)
			[self showError:error.localizedDescription];
		else if(NSString* notice = StopReasonNotice(stopReason))
			[self showNotice:notice];
		[self updateStatus];
	}];
}

- (void)failPendingPrompt
{
	if(!_pendingText && !_pendingAttachments)
		return;
	_pendingText        = nil;
	_pendingAttachments = nil;
	_promptView.working = NO;
	[self showNotice:@"Your message wasn’t sent. Send it again to retry."];
}

- (void)promptViewDidRequestStop:(AgentPromptView*)promptView
{
	if(_pendingText || _pendingAttachments)
	{
		_pendingText        = nil;
		_pendingAttachments = nil;
		_promptView.working = NO;
		[self showNotice:@"Stopped."];
	}
	[_session cancel];
}

- (NSArray<NSDictionary*>*)slashCommandsForPromptView:(AgentPromptView*)promptView
{
	return _session.availableCommands ?: @[ ];
}

- (BOOL)promptViewAcceptsImages:(AgentPromptView*)promptView
{
	return [_session.agentCapabilities[@"promptCapabilities"][@"image"] boolValue];
}

// ===============
// = Add Context =
// ===============

- (NSMenu*)addContextMenuForPromptView:(AgentPromptView*)promptView
{
	NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Add Context"];

	AgentAttachment* currentFile = [_delegate respondsToSelector:@selector(currentFileAttachmentForAgentPanel:)] ? [_delegate currentFileAttachmentForAgentPanel:self] : nil;
	NSMenuItem* item = [menu addItemWithTitle:(currentFile ? [NSString stringWithFormat:@"Current File (%@)", currentFile.name] : @"Current File") action:@selector(addAttachmentFromMenu:) keyEquivalent:@""];
	item.target            = self;
	item.representedObject = currentFile;
	item.enabled           = currentFile != nil;

	AgentAttachment* selection = [_delegate respondsToSelector:@selector(selectionAttachmentForAgentPanel:)] ? [_delegate selectionAttachmentForAgentPanel:self] : nil;
	item = [menu addItemWithTitle:(selection ? [NSString stringWithFormat:@"Selection (%@)", selection.name] : @"Selection") action:@selector(addAttachmentFromMenu:) keyEquivalent:@""];
	item.target            = self;
	item.representedObject = selection;
	item.enabled           = selection != nil;

	NSArray<AgentAttachment*>* openFiles = [_delegate respondsToSelector:@selector(openFileAttachmentsForAgentPanel:)] ? [_delegate openFileAttachmentsForAgentPanel:self] : @[ ];
	NSMenuItem* openFilesItem = [menu addItemWithTitle:@"Open Files" action:nil keyEquivalent:@""];
	openFilesItem.submenu = [[NSMenu alloc] initWithTitle:@"Open Files"];
	for(AgentAttachment* attachment in openFiles)
	{
		NSMenuItem* fileItem = [openFilesItem.submenu addItemWithTitle:attachment.name action:@selector(addAttachmentFromMenu:) keyEquivalent:@""];
		fileItem.target            = self;
		fileItem.representedObject = attachment;
		fileItem.toolTip           = attachment.path;
	}
	openFilesItem.enabled = openFiles.count > 0;

	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItemWithTitle:@"Choose Files…" action:@selector(chooseFiles:) keyEquivalent:@""].target = self;
	return menu;
}

- (void)addAttachmentFromMenu:(NSMenuItem*)sender
{
	if(AgentAttachment* attachment = sender.representedObject)
		[_promptView addAttachment:attachment];
	[self focusPrompt];
}

- (void)chooseFiles:(id)sender
{
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.canChooseFiles          = YES;
	panel.canChooseDirectories    = NO;
	panel.allowsMultipleSelection = YES;
	if(NSString* projectPath = [_delegate projectPathForAgentPanel:self])
		panel.directoryURL = [NSURL fileURLWithPath:projectPath isDirectory:YES];

	[panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result){
		if(result != NSModalResponseOK)
			return;
		for(NSURL* url in panel.URLs)
			[_promptView addAttachment:[AgentAttachment fileAttachmentWithPath:url.path text:nil]];
		[self focusPrompt];
	}];
}

// ===================
// = Agent Controls =
// ===================

- (NSPopUpButton*)makeOptionPopUpWithTitle:(NSString*)title
{
	NSPopUpButton* popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	popUp.controlSize = NSControlSizeSmall;
	popUp.font        = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	popUp.toolTip     = title;
	popUp.target      = self;
	[popUp setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	return popUp;
}

- (void)addOption:(NSDictionary*)value toMenu:(NSMenu*)menu
{
	NSMenuItem* item = [menu addItemWithTitle:value[@"name"] ?: [value[@"value"] description] action:nil keyEquivalent:@""];
	item.representedObject = value[@"value"];
	item.toolTip           = value[@"description"];
}

- (void)rebuildOptions
{
	for(NSView* view in _optionsView.arrangedSubviews)
		[view removeFromSuperview];

	if(!_session)
		return;

	// Config options (mode, model, effort, …) supersede the older modes
	for(NSDictionary* option in _session.configOptions)
	{
		if(![option[@"type"] isEqualToString:@"select"] || ![option[@"options"] isKindOfClass:[NSArray class]])
			continue;

		NSPopUpButton* popUp = [self makeOptionPopUpWithTitle:option[@"description"] ? [NSString stringWithFormat:@"%@ — %@", option[@"name"], option[@"description"]] : option[@"name"]];
		popUp.identifier = option[@"id"];
		popUp.action     = @selector(configOptionChanged:);

		for(NSDictionary* entry in option[@"options"])
		{
			if([entry[@"options"] isKindOfClass:[NSArray class]]) // a group
			{
				[popUp.menu addItem:[NSMenuItem sectionHeaderWithTitle:entry[@"name"] ?: @""]];
				for(NSDictionary* value in entry[@"options"])
					[self addOption:value toMenu:popUp.menu];
			}
			else
			{
				[self addOption:entry toMenu:popUp.menu];
			}
		}

		NSInteger index = [popUp indexOfItemWithRepresentedObject:option[@"currentValue"]];
		if(index != -1)
			[popUp selectItemAtIndex:index];
		[_optionsView addArrangedSubview:popUp];
	}

	NSArray* availableModes = _session.modes[@"availableModes"];
	if(!_optionsView.arrangedSubviews.count && [availableModes isKindOfClass:[NSArray class]] && availableModes.count)
	{
		NSPopUpButton* popUp = [self makeOptionPopUpWithTitle:@"Mode"];
		popUp.action = @selector(modeChanged:);
		for(NSDictionary* mode in availableModes)
			[self addOption:@{ @"value": mode[@"id"] ?: @"", @"name": mode[@"name"] ?: mode[@"id"] ?: @"", @"description": mode[@"description"] ?: @"" } toMenu:popUp.menu];
		NSInteger index = [popUp indexOfItemWithRepresentedObject:_session.modes[@"currentModeId"]];
		if(index != -1)
			[popUp selectItemAtIndex:index];
		[_optionsView addArrangedSubview:popUp];
	}
}

- (void)configOptionChanged:(NSPopUpButton*)sender
{
	__weak AgentPanelViewController* weakSelf = self;
	[_session setConfigOption:sender.identifier value:sender.selectedItem.representedObject completion:^(NSError* error){
		if(error)
			[weakSelf showError:[NSString stringWithFormat:@"Couldn’t change %@: %@", sender.toolTip, error.localizedDescription]];
		[weakSelf rebuildOptions];
	}];
}

- (void)modeChanged:(NSPopUpButton*)sender
{
	__weak AgentPanelViewController* weakSelf = self;
	[_session setMode:sender.selectedItem.representedObject completion:^(NSError* error){
		if(error)
			[weakSelf showError:[NSString stringWithFormat:@"Couldn’t change mode: %@", error.localizedDescription]];
		[weakSelf rebuildOptions];
	}];
}

- (void)updateStatus
{
	NSString* status;
	if(_creatingSession || _session.state == AgentSessionStateStarting)
		status = [NSString stringWithFormat:@"Starting %@…", _agent.name];
	else if(!_session || _session.state == AgentSessionStateFailed || _session.state == AgentSessionStateTerminated)
		status = @"Not running";
	else if(_usageText)
		status = _usageText;
	else
		status = _session.agentInfo[@"version"] ? [NSString stringWithFormat:@"%@ %@", _session.agentInfo[@"title"] ?: _agent.name, _session.agentInfo[@"version"]] : _agent.name;

	_statusField.stringValue = status;
	_statusField.toolTip     = _session.workingDirectory;
}

// =========================
// = AgentSessionDelegate =
// =========================

- (void)agentSessionDidChangeState:(AgentSession*)session
{
	if(session != _session)
		return;
	if(session.state == AgentSessionStateTerminated)
	{
		_promptView.working = NO;
		[self showError:[NSString stringWithFormat:@"%@ stopped running. Send a message to start it again.", _agent.name]];
		[self rebuildOptions];
	}
	[self updateStatus];
}

- (void)agentSessionDidChangeConfiguration:(AgentSession*)session
{
	if(session == _session)
		[self rebuildOptions];
}

- (void)agentSession:(AgentSession*)session didReceiveUpdate:(NSDictionary*)update
{
	if(session != _session)
		return;

	if([update[@"sessionUpdate"] isEqualToString:@"usage_update"])
	{
		double used = [update[@"used"] doubleValue], size = [update[@"size"] doubleValue];
		_usageText = size > 0 ? [NSString stringWithFormat:@"%@ / %@ tokens", FormatTokenCount(used), FormatTokenCount(size)] : nil;
		if(NSDictionary* cost = update[@"cost"])
			_usageText = [NSString stringWithFormat:@"%@ · %.2f %@", _usageText ?: @"", [cost[@"amount"] doubleValue], cost[@"currency"] ?: @""];
		[self updateStatus];
		return;
	}

	if(AgentTranscriptItem* item = [_transcript applyUpdate:update])
		[self showItem:item];
}

- (void)agentSession:(AgentSession*)session didReceiveStandardError:(NSString*)text
{
	NSLog(@"[Agent %@] %@", _agent.identifier, [text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
}

// ================================
// = AgentTranscriptViewDelegate =
// ================================

- (void)transcriptView:(AgentTranscriptView*)transcriptView insertCode:(NSString*)code
{
	if([_delegate respondsToSelector:@selector(agentPanel:insertText:)])
		[_delegate agentPanel:self insertText:code];
}

- (void)transcriptView:(AgentTranscriptView*)transcriptView openFile:(NSString*)path line:(NSUInteger)line
{
	if(![path hasPrefix:@"/"])
		path = [[_delegate projectPathForAgentPanel:self] stringByAppendingPathComponent:path];
	if([_delegate respondsToSelector:@selector(agentPanel:openFile:line:)])
		[_delegate agentPanel:self openFile:path line:line];
}
@end
