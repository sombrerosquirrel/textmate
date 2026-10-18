#import "AgentPanelViewController.h"
#import "AgentPromptView.h"
#import "AgentTranscriptView.h"
#import "AgentChangesView.h"
#import <AgentClient/AgentDiff.h>
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

// Views don’t clip to their bounds by default (macOS 14 SDK), and the dirty
// rect can extend past them; filling all of it painted over the editor
- (void)drawRect:(NSRect)rect
{
	[NSColor.tmSidebarBackgroundColor setFill];
	NSRectFill(NSIntersectionRect(rect, self.bounds));
}
@end

static NSView* Separator ()
{
	NSBox* box = [[NSBox alloc] initWithFrame:NSZeroRect];
	box.boxType = NSBoxSeparator;
	return box;
}

@interface AgentPanelViewController () <AgentSessionDelegate, AgentPromptViewDelegate, AgentTranscriptViewDelegate, AgentFileSystemDelegate, AgentChangesViewDelegate, AgentTerminalManagerDelegate>
{
	AgentDescriptor* _agent;
	AgentSession* _session;
	BOOL _creatingSession;
	AgentFileSystem* _fileSystem;              // one per chat, so its changes outlive an agent restart
	AgentTerminalManager* _terminals;          // one per chat, so output stays visible after a restart
	NSMutableDictionary<NSString*, void(^)(NSDictionary*)>* _permissionReplies; // transcript item identifier → reply
	NSMutableSet<NSString*>* _finishedToolCallIds; // edit tool calls whose files have been compared

	AgentTranscript* _transcript;
	NSString* _pendingText;                     // sent once the session is ready
	NSArray<AgentAttachment*>* _pendingAttachments;
	AgentAttachment* _pendingCurrentFile; // the file open in the editor when the prompt was sent
	NSString* _usageText;

	NSPopUpButton* _agentPopUp;
	AgentTranscriptView* _transcriptView;
	AgentChangesView* _changesView;
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
		_permissionReplies = [NSMutableDictionary dictionary];
		_finishedToolCallIds = [NSMutableSet set];
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

	_changesView = [[AgentChangesView alloc] initWithFrame:NSZeroRect];
	_changesView.delegate = self;

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

	NSStackView* stack = [NSStackView stackViewWithViews:@[ header, Separator(), transcriptScrollView, Separator(), _changesView, _promptView, footer ]];
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
		_session.delegate   = self;
		// Claude Code runs commands itself; ask it to report their output as terminals
		_session.clientCapabilities = @{ @"_meta": @{ @"terminal_output": @YES, @"terminal_output_delta": @YES } };
		_session.fileSystem = [self fileSystemForProjectPath:projectPath];
		_session.terminals  = [self terminalsForProjectPath:projectPath environment:session.connection.environment];
		[session startWithCompletion:^(NSError* error){
			if(session != _session)
				return;
			if(error)
			{
				[self showError:[self message:[NSString stringWithFormat:@"%@ didn’t start: %@", agent.name, error.localizedDescription] withOutputOfSession:session]];
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

- (AgentFileSystem*)fileSystemForProjectPath:(NSString*)projectPath
{
	if(![_fileSystem.rootDirectory isEqualToString:projectPath.stringByStandardizingPath])
	{
		_fileSystem = [[AgentFileSystem alloc] initWithRootDirectory:projectPath];
		_fileSystem.delegate = self;
		_changesView.rootDirectory = _fileSystem.rootDirectory;
		_changesView.changes       = @[ ];
	}
	if([_delegate respondsToSelector:@selector(documentProviderForAgentPanel:)])
		_fileSystem.documentProvider = [_delegate documentProviderForAgentPanel:self];
	return _fileSystem;
}

- (AgentTerminalManager*)terminalsForProjectPath:(NSString*)projectPath environment:(NSDictionary*)environment
{
	if(![_terminals.workingDirectory isEqualToString:projectPath])
	{
		[_terminals killAll];
		_terminals = [[AgentTerminalManager alloc] initWithWorkingDirectory:projectPath queue:dispatch_get_main_queue()];
		_terminals.delegate = self;
		_transcriptView.terminalManager = _terminals;
	}
	_terminals.environment = environment;
	return _terminals;
}

- (void)closeSession
{
	[self cancelPendingPermissionRequests];
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
	_fileSystem = nil;
	[_terminals killAll];
	_terminals = nil;
	[_finishedToolCallIds removeAllObjects];
	_transcriptView.terminalManager = nil;
	_changesView.changes = @[ ];
	[_transcript removeAllItems];
	[_transcriptView reloadData];
	_pendingText        = nil;
	_pendingAttachments = nil;
	_pendingCurrentFile = nil;
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

// The agent’s last error output usually says why it failed, e.g. an npx too
// old for `-y`, or a missing login
- (NSString*)message:(NSString*)message withOutputOfSession:(AgentSession*)session
{
	NSString* output = session.recentStandardError;
	return output ? [NSString stringWithFormat:@"%@\n\nOutput from %@:\n%@", message, _agent.name, output] : message;
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
	_pendingCurrentFile = [_delegate respondsToSelector:@selector(currentFileAttachmentForAgentPanel:)] ? [_delegate currentFileAttachmentForAgentPanel:self] : nil;
	promptView.working  = YES;

	if(_session.state == AgentSessionStateReady)
			[self sendPendingPrompt];
	else	[self startSessionIfNeeded];
	[self updateStatus];
}

- (void)sendPendingPrompt
{
	NSDictionary* promptCapabilities = _session.agentCapabilities[@"promptCapabilities"];
	NSArray* prompt = [AgentAttachment promptWithText:_pendingText attachments:_pendingAttachments currentFile:_pendingCurrentFile promptCapabilities:promptCapabilities];
	_pendingText        = nil;
	_pendingAttachments = nil;
	_pendingCurrentFile = nil;

	AgentSession* session = _session;
	[session sendPrompt:prompt completion:^(NSString* stopReason, NSError* error){
		if(session != _session)
			return;
		_promptView.working = NO;
		[self cancelPendingPermissionRequests];
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
	_pendingCurrentFile = nil;
	_promptView.working = NO;
	[self showNotice:@"Your message wasn’t sent. Send it again to retry."];
}

- (void)promptViewDidRequestStop:(AgentPromptView*)promptView
{
	if(_pendingText || _pendingAttachments)
	{
		_pendingText        = nil;
		_pendingAttachments = nil;
		_pendingCurrentFile = nil;
		_promptView.working = NO;
		[self showNotice:@"Stopped."];
	}
	[self cancelPendingPermissionRequests];
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
	else if(_transcript.pendingPermissionItems.count)
		status = @"Waiting for your approval";
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
		[self cancelPendingPermissionRequests];
		_promptView.working = NO;
		[self showError:[self message:[NSString stringWithFormat:@"%@ stopped running. Send a message to start it again.", _agent.name] withOutputOfSession:session]];
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
	{
		[self showItem:item];
		if(item.kind == AgentTranscriptItemKindToolCall)
			[self trackFilesOfToolCall:item.toolCall];
	}
}

// Agents mostly edit files themselves rather than through fs/write_text_file.
// Remember each file an edit tool call names before it runs, and compare when
// it finishes, so the change shows up in the changed-files list.
- (void)trackFilesOfToolCall:(NSDictionary*)toolCall
{
	NSString* toolCallId = [toolCall[@"toolCallId"] description];
	if(!_fileSystem || !toolCallId || [_finishedToolCallIds containsObject:toolCallId])
		return;

	NSMutableOrderedSet<NSString*>* paths = [NSMutableOrderedSet orderedSet];
	BOOL edits = [@[ @"edit", @"delete", @"move" ] containsObject:toolCall[@"kind"] ?: @""];
	for(NSDictionary* content in [toolCall[@"content"] isKindOfClass:[NSArray class]] ? toolCall[@"content"] : @[ ])
	{
		if([content isKindOfClass:[NSDictionary class]] && [content[@"type"] isEqualToString:@"diff"] && [content[@"path"] isKindOfClass:[NSString class]])
		{
			[paths addObject:content[@"path"]];
			edits = YES;
		}
	}
	if(!edits)
		return;
	for(NSDictionary* location in [toolCall[@"locations"] isKindOfClass:[NSArray class]] ? toolCall[@"locations"] : @[ ])
	{
		if([location isKindOfClass:[NSDictionary class]] && [location[@"path"] isKindOfClass:[NSString class]])
			[paths addObject:location[@"path"]];
	}

	NSString* status = toolCall[@"status"];
	BOOL finished = [status isEqualToString:@"completed"] || [status isEqualToString:@"failed"];
	if(finished)
		[_finishedToolCallIds addObject:toolCallId];
	for(NSString* path in paths)
	{
		if(finished)
				[_fileSystem didChangeFileAtPath:path];
		else	[_fileSystem willChangeFileAtPath:path];
	}
}

- (void)agentSession:(AgentSession*)session requestPermission:(NSDictionary*)params reply:(void(^)(NSDictionary* outcome))reply
{
	if(session != _session)
		return reply(@{ @"outcome": @"cancelled" });

	AgentTranscriptItem* item = [_transcript addPermissionRequest:params];
	_permissionReplies[item.identifier] = reply;
	[self showItem:item];
	[self updateStatus];

	if(!NSApp.isActive)
		[NSApp requestUserAttention:NSInformationalRequest];
}

- (void)resolvePermissionItem:(AgentTranscriptItem*)item selectedOptionId:(NSString*)optionId
{
	void(^reply)(NSDictionary*) = _permissionReplies[item.identifier];
	[_permissionReplies removeObjectForKey:item.identifier];
	[_transcript resolvePermissionItem:item selectedOptionId:optionId];
	[self showItem:item];
	[self updateStatus];

	if(reply)
		reply(optionId ? @{ @"outcome": @"selected", @"optionId": optionId } : @{ @"outcome": @"cancelled" });
}

- (void)cancelPendingPermissionRequests
{
	for(AgentTranscriptItem* item in _transcript.pendingPermissionItems)
		[self resolvePermissionItem:item selectedOptionId:nil];
}

- (void)agentTerminalManager:(AgentTerminalManager*)manager didUpdateTerminal:(AgentTerminal*)terminal
{
	if(manager != _terminals)
		return;

	for(AgentTranscriptItem* item in _transcript.items)
	{
		NSArray* contents = item.kind == AgentTranscriptItemKindToolCall && [item.toolCall[@"content"] isKindOfClass:[NSArray class]] ? item.toolCall[@"content"] : @[ ];
		for(NSDictionary* content in contents)
		{
			if([content isKindOfClass:[NSDictionary class]] && [content[@"terminalId"] isEqual:terminal.terminalId])
				[self showItem:item];
		}
	}
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

- (void)transcriptView:(AgentTranscriptView*)transcriptView applyCode:(NSString*)code
{
	if(![_delegate respondsToSelector:@selector(agentPanel:applyText:)])
		return;

	NSDictionary* result = [_delegate agentPanel:self applyText:code];
	if(!result)
		return [self showError:@"There is no document to apply the code to."];

	// Listed with the agent’s changes, to review or undo
	if([result[@"path"] isKindOfClass:[NSString class]])
		[_fileSystem recordChangeAtPath:[result[@"path"] stringByStandardizingPath] originalText:result[@"originalText"] currentText:result[@"currentText"]];
}

- (void)transcriptView:(AgentTranscriptView*)transcriptView showDiffOfFile:(NSString*)path oldText:(NSString*)oldText newText:(NSString*)newText
{
	[self showDiffOfFile:path oldText:oldText newText:newText];
}

- (void)transcriptView:(AgentTranscriptView*)transcriptView selectPermissionOption:(NSString*)optionId forItem:(AgentTranscriptItem*)item
{
	if(_permissionReplies[item.identifier])
		[self resolvePermissionItem:item selectedOptionId:optionId];
}

- (void)transcriptView:(AgentTranscriptView*)transcriptView openFile:(NSString*)path line:(NSUInteger)line
{
	if(![path hasPrefix:@"/"])
		path = [[_delegate projectPathForAgentPanel:self] stringByAppendingPathComponent:path];
	if([_delegate respondsToSelector:@selector(agentPanel:openFile:line:)])
		[_delegate agentPanel:self openFile:path line:line];
}

// ===================
// = Changed Files =
// ===================

- (void)agentFileSystemDidChangeChanges:(AgentFileSystem*)fileSystem
{
	if(fileSystem == _fileSystem)
		_changesView.changes = fileSystem.changes;
}

- (NSString*)displayNameForPath:(NSString*)path
{
	NSString* root = _fileSystem.rootDirectory;
	if(root && [path hasPrefix:[root stringByAppendingString:@"/"]])
		return [path substringFromIndex:root.length + 1];
	return path.lastPathComponent;
}

- (void)showDiffOfFile:(NSString*)path oldText:(NSString*)oldText newText:(NSString*)newText
{
	if(![_delegate respondsToSelector:@selector(agentPanel:showDiff:title:)])
		return;

	NSString* name  = [self displayNameForPath:path ?: @"file"];
	AgentDiff* diff = [AgentDiff diffWithOldText:oldText newText:newText contextLines:3];
	NSString* text  = diff.isEmpty ? @"No changes.\n" : [diff unifiedDiffWithOldName:(oldText ? [@"a/" stringByAppendingString:name] : @"/dev/null") newName:[@"b/" stringByAppendingString:name]];
	[_delegate agentPanel:self showDiff:text title:[NSString stringWithFormat:@"%@ (agent changes).diff", name.lastPathComponent]];
}

- (void)changesView:(AgentChangesView*)changesView openChange:(AgentFileChange*)change
{
	if([_delegate respondsToSelector:@selector(agentPanel:openFile:line:)])
		[_delegate agentPanel:self openFile:change.path line:0];
}

- (void)changesView:(AgentChangesView*)changesView showDiffOfChange:(AgentFileChange*)change
{
	[self showDiffOfFile:change.path oldText:change.originalText newText:change.currentText ?: @""];
}

- (void)changesView:(AgentChangesView*)changesView keepChanges:(NSArray<AgentFileChange*>*)changes
{
	if(changes.count == _fileSystem.changes.count)
	{
		[_fileSystem keepAllChanges];
		return;
	}
	for(AgentFileChange* change in changes)
		[_fileSystem keepChange:change];
}

- (void)changesView:(AgentChangesView*)changesView undoChanges:(NSArray<AgentFileChange*>*)changes
{
	NSMutableArray<NSString*>* editedSince = [NSMutableArray array];
	for(AgentFileChange* change in changes)
	{
		if([_fileSystem hasFileChangedSinceChange:change])
			[editedSince addObject:[self displayNameForPath:change.path]];
	}

	if(!editedSince.count)
		return [self undoChanges:changes];

	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText     = editedSince.count == 1 ? [NSString stringWithFormat:@"“%@” has changed since the agent edited it.", editedSince.firstObject] : @"Some files have changed since the agent edited them.";
	alert.informativeText = [NSString stringWithFormat:@"Undo restores the file as it was before the agent changed it, so later edits are lost too.%@", editedSince.count > 1 ? [@"\n\n" stringByAppendingString:[editedSince componentsJoinedByString:@"\n"]] : @""];
	[alert addButtonWithTitle:@"Undo Anyway"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn)
			[self undoChanges:changes];
	}];
}

- (void)undoChanges:(NSArray<AgentFileChange*>*)changes
{
	for(AgentFileChange* change in changes)
	{
		NSError* error;
		if(![_fileSystem undoChange:change force:YES error:&error])
			[self showError:error.localizedDescription];
	}
}
@end
