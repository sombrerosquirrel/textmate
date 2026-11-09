#import "AgentsPreferences.h"
#import <AgentClient/AgentRegistry.h>
#import <AgentClient/AgentKeychain.h>
#import "Keys.h"
#import <OakAppKit/OakUIConstructionFunctions.h>

static NSString* const kColumnEnabled = @"enabled";
static NSString* const kColumnName    = @"name";
static NSString* const kColumnType    = @"type";
static NSString* const kColumnTarget  = @"target";

static NSRect const kTabItemFrame = NSMakeRect(0, 0, 560, 450);

static NSArray<NSString*>* const kMCPServerTypes = @[ @"stdio", @"http", @"sse" ];

// Variables are edited as text, one per line: “NAME=value” for environment
// variables, “Name: value” for HTTP headers. Blank lines and lines starting
// with # are ignored.
static NSString* TextFromVariables (NSDictionary<NSString*, NSString*>* variables, NSString* separator)
{
	NSMutableString* res = [NSMutableString string];
	for(NSString* key in [variables.allKeys sortedArrayUsingSelector:@selector(compare:)])
		[res appendFormat:@"%@%@%@\n", key, separator, variables[key]];
	return res;
}

static NSDictionary<NSString*, NSString*>* VariablesFromText (NSString* text, NSString* separator)
{
	NSMutableDictionary* res = [NSMutableDictionary dictionary];
	for(NSString* line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
	{
		NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		NSRange range = [trimmed rangeOfString:[separator stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
		if(!trimmed.length || [trimmed hasPrefix:@"#"] || range.location == NSNotFound || range.location == 0)
			continue;
		NSString* key   = [[trimmed substringToIndex:range.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		NSString* value = [[trimmed substringFromIndex:NSMaxRange(range)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		res[key] = value;
	}
	return res;
}

static NSTextField* HintLabel (NSString* text)
{
	NSTextField* res = [NSTextField wrappingLabelWithString:text];
	res.font      = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	res.textColor = NSColor.secondaryLabelColor;
	res.preferredMaxLayoutWidth = 270;
	return res;
}

static NSScrollView* VariablesEditor (NSTextView* __strong* textView, id<NSTextViewDelegate> delegate)
{
	NSScrollView* scrollView = [NSTextView scrollableTextView];
	scrollView.borderType = NSBezelBorder;
	NSTextView* res = scrollView.documentView;
	res.font                                 = [NSFont userFixedPitchFontOfSize:NSFont.smallSystemFontSize];
	res.richText                             = NO;
	res.automaticQuoteSubstitutionEnabled    = NO;
	res.automaticDashSubstitutionEnabled     = NO;
	res.automaticTextReplacementEnabled      = NO;
	res.automaticSpellingCorrectionEnabled   = NO;
	res.continuousSpellCheckingEnabled       = NO;
	res.delegate                             = delegate;
	*textView = res;
	return scrollView;
}

static NSTableColumn* Column (NSUserInterfaceItemIdentifier identifier, NSString* title, BOOL editable, CGFloat width, NSTableColumnResizingOptions resizingMask)
{
	NSTableColumn* res = [[NSTableColumn alloc] initWithIdentifier:identifier];
	res.title        = title;
	res.editable     = editable;
	res.width        = width;
	res.resizingMask = resizingMask;
	if(resizingMask == NSTableColumnNoResizing)
	{
		res.minWidth = width;
		res.maxWidth = width;
	}
	return res;
}

static CGFloat const kRowHeight = 24;

// Text cells draw at the top of their row; this one centres its text vertically, also while editing
@interface AgentsCenteredTextFieldCell : NSTextFieldCell
@end

@implementation AgentsCenteredTextFieldCell
- (NSRect)centeredRectForBounds:(NSRect)rect
{
	CGFloat height = ceil(self.font.ascender - self.font.descender + self.font.leading) + 2;
	if(height < NSHeight(rect))
	{
		rect.origin.y  += floor((NSHeight(rect) - height) / 2);
		rect.size.height = height;
	}
	return rect;
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView*)view
{
	[super drawInteriorWithFrame:[self centeredRectForBounds:frame] inView:view];
}

- (void)editWithFrame:(NSRect)rect inView:(NSView*)view editor:(NSText*)editor delegate:(id)delegate event:(NSEvent*)event
{
	[super editWithFrame:[self centeredRectForBounds:rect] inView:view editor:editor delegate:delegate event:event];
}

- (void)selectWithFrame:(NSRect)rect inView:(NSView*)view editor:(NSText*)editor delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length
{
	[super selectWithFrame:[self centeredRectForBounds:rect] inView:view editor:editor delegate:delegate start:start length:length];
}
@end

static NSTextFieldCell* TextCell (NSFont* font = nil)
{
	NSTextFieldCell* res = [[AgentsCenteredTextFieldCell alloc] initTextCell:@""];
	res.font          = font ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
	res.lineBreakMode = NSLineBreakByTruncatingTail;
	res.editable      = YES;
	return res;
}

static NSButtonCell* CheckBoxCell ()
{
	NSButtonCell* res = [[NSButtonCell alloc] init];
	res.buttonType  = NSButtonTypeSwitch;
	res.controlSize = NSControlSizeRegular;
	res.title       = @"";
	return res;
}

static NSTableView* TableView (NSArray<NSTableColumn*>* columns, id<NSTableViewDelegate, NSTableViewDataSource> delegate, NSScrollView** scrollView)
{
	NSTableView* res = [[NSTableView alloc] initWithFrame:NSZeroRect];
	res.allowsColumnReordering  = NO;
	res.allowsEmptySelection    = YES;
	res.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	res.rowHeight               = kRowHeight;
	res.delegate                = delegate;
	res.dataSource              = delegate;
	for(NSTableColumn* column in columns)
		[res addTableColumn:column];

	*scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	(*scrollView).hasVerticalScroller = YES;
	(*scrollView).autohidesScrollers  = YES;
	(*scrollView).borderType          = NSBezelBorder;
	(*scrollView).documentView        = res;
	return res;
}

static void AddAddRemoveButtons (NSButton* __strong* addButton, NSButton* __strong* removeButton, id target, SEL add, SEL remove)
{
	*addButton    = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameAddTemplate] target:target action:add];
	*removeButton = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameRemoveTemplate] target:target action:remove];
	for(NSButton* button in @[ *addButton, *removeButton ])
		button.bezelStyle = NSBezelStyleSmallSquare;
}

@interface AgentsPreferences () <NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate, NSTextViewDelegate>
{
	NSMutableArray<AgentDescriptor*>* _agents;
	NSMutableArray<AgentMCPServer*>* _servers;

	NSTableView* _agentsTableView;
	NSButton* _removeAgentButton;
	NSTextField* _nameField;
	NSTextField* _commandField;
	NSTextView* _environmentView;
	NSButton* _usesAPIKeyCheckBox;
	NSTextField* _apiKeyVariableField;
	NSSecureTextField* _apiKeyField;
	NSButton* _restoreButton;
	NSArray<NSControl*>* _agentControls;
	NSString* _apiKeyAgentIdentifier; // the agent whose key _apiKeyField shows

	NSTableView* _serversTableView;
	NSButton* _removeServerButton;
	NSTextField* _serverVariablesLabel;
	NSTextView* _serverVariablesView;
}
@end

// Whether Restore Defaults has anything to restore (on/off and whether to use
// the API key are kept)
static BOOL DiffersFromDefault (AgentDescriptor* agent)
{
	AgentDescriptor* defaultAgent = [AgentRegistry defaultAgentWithIdentifier:agent.identifier];
	if(!defaultAgent)
		return NO;
	return ![agent.name isEqualToString:defaultAgent.name] || ![agent.commandLine isEqualToString:defaultAgent.commandLine] || ![agent.environment isEqual:defaultAgent.environment] || ![agent.apiKeyVariable isEqualToString:defaultAgent.apiKeyVariable];
}

@implementation AgentsPreferences
- (NSImage*)toolbarItemImage { return PreferencesToolbarImage(@"sparkles", @"Agents", nil); }

- (id)init
{
	if(self = [self initWithNibName:nil bundle:nil])
	{
		self.identifier = @"Agents";
		self.title      = @"Agents";
		[self reloadData];
	}
	return self;
}

- (void)reloadData
{
	// Copies, edited here and saved as a whole
	_agents  = [NSMutableArray array];
	_servers = [NSMutableArray array];
	for(AgentDescriptor* agent in AgentRegistry.agents)
		[_agents addObject:[agent copy]];
	for(AgentMCPServer* server in AgentRegistry.MCPServers)
		[_servers addObject:[server copy]];
}

- (void)viewWillAppear
{
	[super viewWillAppear];
	[self reloadData];
	[_agentsTableView reloadData];
	[_serversTableView reloadData];
	if(_agentsTableView.selectedRow == -1 && _agents.count)
		[_agentsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[self updateAgentForm];
	[self updateServerForm];
}

- (BOOL)commitEditing
{
	// Ends editing in text fields, which saves the API key
	[self.view.window makeFirstResponder:nil];
	return YES;
}

- (void)loadView
{
	NSTabView* tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 582, 500)];
	NSTabViewItem* agentsItem  = [[NSTabViewItem alloc] initWithIdentifier:@"agents"];
	agentsItem.label = @"Agents";
	agentsItem.view  = [self makeAgentsView];
	NSTabViewItem* serversItem = [[NSTabViewItem alloc] initWithIdentifier:@"mcp"];
	serversItem.label = @"MCP Servers";
	serversItem.view  = [self makeServersView];
	[tabView addTabViewItem:agentsItem];
	[tabView addTabViewItem:serversItem];

	// NSTabView doesn’t size itself to its items, so it gets a size they fit
	// in. 582 + margins = 622, the other panes’ width: a different width
	// resizes the window, and its centred toolbar icons move.
	NSView* view = [[NSView alloc] initWithFrame:NSZeroRect];
	OakAddAutoLayoutViewsToSuperview(@[ tabView ], view);
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[tabView(==582)]-|" options:0 metrics:nil views:@{ @"tabView": tabView }]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-[tabView(>=500)]-|" options:0 metrics:nil views:@{ @"tabView": tabView }]];
	// The preferences window keeps each pane at its frame’s size
	view.frame = (NSRect){ .size = view.fittingSize };
	self.view = view;
}

// ==========
// = Agents =
// ==========

- (NSView*)makeAgentsView
{
	NSTableColumn* enabledColumn = Column(kColumnEnabled, @"", YES, 16, NSTableColumnNoResizing);
	enabledColumn.dataCell = CheckBoxCell();
	enabledColumn.headerToolTip = @"Show in the agent panel";
	NSTableColumn* nameColumn = Column(kColumnName, @"Agent", NO, 150, NSTableColumnAutoresizingMask);
	nameColumn.dataCell = TextCell();

	NSScrollView* tableScrollView;
	_agentsTableView = TableView(@[ enabledColumn, nameColumn ], self, &tableScrollView);

	NSButton* addButton;
	AddAddRemoveButtons(&addButton, &_removeAgentButton, self, @selector(addAgent:), @selector(removeAgent:));

	_nameField    = [NSTextField textFieldWithString:@""];
	_commandField = [NSTextField textFieldWithString:@""];
	_commandField.placeholderString = @"command --acp";
	_commandField.font = [NSFont userFixedPitchFontOfSize:NSFont.smallSystemFontSize];
	for(NSTextField* field in @[ _nameField, _commandField ])
		field.delegate = self;

	NSScrollView* environmentScrollView = VariablesEditor(&_environmentView, self);

	_usesAPIKeyCheckBox = OakCreateCheckBox(@"Use an API key from the Keychain");
	_usesAPIKeyCheckBox.target = self;
	_usesAPIKeyCheckBox.action = @selector(toggleUsesAPIKey:);

	_apiKeyVariableField = [NSTextField textFieldWithString:@""];
	_apiKeyVariableField.placeholderString = @"VARIABLE_NAME";
	_apiKeyVariableField.font     = [NSFont userFixedPitchFontOfSize:NSFont.smallSystemFontSize];
	_apiKeyVariableField.delegate = self;

	_apiKeyField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
	_apiKeyField.placeholderString = @"Not set";
	_apiKeyField.delegate = self;

	_restoreButton = OakCreateButton(@"Restore Defaults");
	_restoreButton.target = self;
	_restoreButton.action = @selector(restoreDefaults:);

	NSGridView* form = [NSGridView gridViewWithViews:@[
		@[ OakCreateLabel(@"Name:"),         _nameField                                                  ],
		@[ OakCreateLabel(@"Command:"),      _commandField                                               ],
		@[ NSGridCell.emptyContentView,      HintLabel(@"Runs in the project folder with your login shell’s PATH. Quote words that contain spaces.") ],
		@[ OakCreateLabel(@"Environment:"),  environmentScrollView                                       ],
		@[ NSGridCell.emptyContentView,      HintLabel(@"One NAME=value per line.")                      ],
		@[ OakCreateLabel(@"API key:"),      _usesAPIKeyCheckBox                                         ],
		@[ OakCreateLabel(@"Variable:"),     _apiKeyVariableField                                        ],
		@[ OakCreateLabel(@"Key:"),          _apiKeyField                                                ],
		@[ NSGridCell.emptyContentView,      HintLabel(@"Without a key, the agent uses its own sign-in (e.g. your Claude subscription, or copilot login).") ],
		@[ NSGridCell.emptyContentView,      _restoreButton                                              ],
	]];
	form.rowSpacing    = 6;
	form.columnSpacing = 8;
	[form columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	for(NSInteger row = 0; row < form.numberOfRows; ++row)
		[form rowAtIndex:row].rowAlignment = NSGridRowAlignmentFirstBaseline;
	[form rowAtIndex:3].rowAlignment = NSGridRowAlignmentNone;
	[form rowAtIndex:3].yPlacement   = NSGridCellPlacementTop;
	[form cellForView:_restoreButton].xPlacement = NSGridCellPlacementLeading;
	// Preferred sizes: required ones could exceed the tab item while it’s being sized
	NSMutableArray<NSLayoutConstraint*>* sizes = [NSMutableArray arrayWithObjects:[environmentScrollView.heightAnchor constraintEqualToConstant:70], [_apiKeyVariableField.widthAnchor constraintEqualToConstant:190], nil];
	for(NSView* view in @[ _nameField, _commandField, environmentScrollView, _apiKeyField ])
		[sizes addObject:[view.widthAnchor constraintEqualToConstant:270]];
	for(NSLayoutConstraint* constraint in sizes)
		constraint.priority = NSLayoutPriorityDefaultHigh;
	[NSLayoutConstraint activateConstraints:sizes];

	_agentControls = @[ _nameField, _commandField, _usesAPIKeyCheckBox, _apiKeyVariableField, _apiKeyField, _restoreButton ];

	NSTextField* footnote = HintLabel(@"In a project’s .tm_properties, agentName picks the agent to use (by name) and agentCommand replaces its command.");
	footnote.preferredMaxLayoutWidth = 530;

	NSButton* fileBrowserFolderCheckBox = OakCreateCheckBox(@"Without a project or saved document, start agents in the File Browser’s folder");
	fileBrowserFolderCheckBox.state  = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsAgentUsesFileBrowserFolderKey] ? NSControlStateValueOn : NSControlStateValueOff;
	fileBrowserFolderCheckBox.target = self;
	fileBrowserFolderCheckBox.action = @selector(toggleUsesFileBrowserFolder:);
	NSTextField* fileBrowserFolderHint = HintLabel(@"Agents start in the project folder, where they find its .claude settings, or else in the folder of the document, if it has been saved. Otherwise they start in the folder at the top of the File Browser (Claude Code then asks before working outside it), or with this off, in your home folder. Takes effect when the agent next starts (e.g. New Chat).");
	fileBrowserFolderHint.preferredMaxLayoutWidth = 510;

	NSPopUpButton* chatStylePopUp = OakCreatePopUpButton();
	[chatStylePopUp addItemsWithTitles:@[ @"Built-in", @"GitHub" ]];
	[chatStylePopUp selectItemAtIndex:[[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsAgentChatStyleKey] isEqualToString:@"github"] ? 1 : 0];
	chatStylePopUp.target = self;
	chatStylePopUp.action = @selector(takeChatStyleFrom:);
	NSTextField* chatStyleLabel = OakCreateLabel(@"Chat text style:");
	NSTextField* chatStyleHint  = HintLabel(@"How the agent’s replies look: like the built-in Markdown preview, or like GitHub (fonts, colours, spacing, headings, quotes and tables). Code blocks keep the editor’s theme.");
	chatStyleHint.preferredMaxLayoutWidth = 510;

	NSView* view = [[NSView alloc] initWithFrame:kTabItemFrame]; // tab items are sized by autoresizing, and nothing fits in 0×0
	NSDictionary* views = @{ @"table": tableScrollView, @"add": addButton, @"remove": _removeAgentButton, @"form": form, @"footnote": footnote, @"fileBrowserFolder": fileBrowserFolderCheckBox, @"fileBrowserFolderHint": fileBrowserFolderHint, @"chatStyleLabel": chatStyleLabel, @"chatStyle": chatStylePopUp, @"chatStyleHint": chatStyleHint };
	OakAddAutoLayoutViewsToSuperview(views.allValues, view);
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[table(==150@750)]-12-[form]-(>=12)-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[add(==20)]-(-1)-[remove(==add)]" options:NSLayoutFormatAlignAllTop|NSLayoutFormatAlignAllBottom metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[footnote]-12-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[fileBrowserFolder]-(>=12)-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-32-[fileBrowserFolderHint]-12-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[chatStyleLabel]-8-[chatStyle]-(>=12)-|" options:NSLayoutFormatAlignAllFirstBaseline metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-32-[chatStyleHint]-12-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-12-[table]-8-[add(==19)]-12-[footnote]-16-[fileBrowserFolder]-4-[fileBrowserFolderHint]-16-[chatStyle]-4-[chatStyleHint]-12-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-12-[form]-(>=8@750)-[footnote]" options:0 metrics:nil views:views]];
	return view;
}

- (AgentDescriptor*)selectedAgent
{
	NSInteger row = _agentsTableView.selectedRow;
	return row >= 0 && row < _agents.count ? _agents[row] : nil;
}

- (void)saveAgents
{
	[AgentRegistry setAgents:_agents];
}

- (void)updateAgentForm
{
	AgentDescriptor* agent = self.selectedAgent;
	for(NSControl* control in _agentControls)
		control.enabled = agent != nil;
	_environmentView.editable = agent != nil;
	_environmentView.textColor = agent ? NSColor.textColor : NSColor.disabledControlTextColor;
	_removeAgentButton.enabled = agent && !agent.builtIn;

	_nameField.stringValue            = agent.name ?: @"";
	_commandField.stringValue         = agent.commandLine ?: @"";
	_environmentView.string           = agent ? TextFromVariables(agent.environment, @"=") : @"";
	_usesAPIKeyCheckBox.state         = agent.usesAPIKey ? NSControlStateValueOn : NSControlStateValueOff;
	_apiKeyVariableField.stringValue  = agent.apiKeyVariable ?: @"";
	_apiKeyVariableField.enabled      = agent && agent.usesAPIKey;
	_apiKeyField.enabled              = agent && agent.usesAPIKey;
	_restoreButton.hidden             = !agent.builtIn;
	_restoreButton.enabled            = DiffersFromDefault(agent);

	if(![_apiKeyAgentIdentifier isEqualToString:agent.identifier])
	{
		_apiKeyAgentIdentifier   = agent.identifier;
		_apiKeyField.stringValue = agent ? [AgentKeychain APIKeyForAgent:agent.identifier] ?: @"" : @"";
	}
}

- (void)addAgent:(id)sender
{
	[self commitEditing];
	AgentDescriptor* agent = [AgentRegistry makeAgent];
	[_agents addObject:agent];
	[self saveAgents];
	[_agentsTableView reloadData];
	[_agentsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:_agents.count - 1] byExtendingSelection:NO];
	[_agentsTableView scrollRowToVisible:_agents.count - 1];
	[self.view.window makeFirstResponder:_nameField];
}

- (void)removeAgent:(id)sender
{
	AgentDescriptor* agent = self.selectedAgent;
	if(!agent || agent.builtIn)
		return;

	NSInteger row = _agentsTableView.selectedRow;
	[_agents removeObjectAtIndex:row];
	[AgentKeychain setAPIKey:nil forAgent:agent.identifier error:nil];
	[self saveAgents];
	[_agentsTableView reloadData];
	if(_agents.count)
		[_agentsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:MIN(row, (NSInteger)_agents.count - 1)] byExtendingSelection:NO];
	[self updateAgentForm];
}

- (void)restoreDefaults:(id)sender
{
	AgentDescriptor* agent = self.selectedAgent;
	AgentDescriptor* defaultAgent = [AgentRegistry defaultAgentWithIdentifier:agent.identifier];
	if(!defaultAgent)
		return;
	defaultAgent.enabled    = agent.enabled;
	defaultAgent.usesAPIKey = agent.usesAPIKey; // the key itself stays in the Keychain
	_agents[_agentsTableView.selectedRow] = defaultAgent;
	[self saveAgents];
	[_agentsTableView reloadData];
	[self updateAgentForm];
}

- (void)takeChatStyleFrom:(NSPopUpButton*)sender
{
	[NSUserDefaults.standardUserDefaults setObject:(sender.indexOfSelectedItem == 1 ? @"github" : @"builtin") forKey:kUserDefaultsAgentChatStyleKey];
}

- (void)toggleUsesFileBrowserFolder:(NSButton*)sender
{
	[NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:kUserDefaultsAgentUsesFileBrowserFolderKey];
}

- (void)toggleUsesAPIKey:(NSButton*)sender
{
	self.selectedAgent.usesAPIKey = sender.state == NSControlStateValueOn;
	[self saveAgents];
	[self updateAgentForm];
	if(self.selectedAgent.usesAPIKey && !_apiKeyField.stringValue.length)
		[self.view.window makeFirstResponder:_apiKeyField];
}

- (void)saveAPIKey
{
	AgentDescriptor* agent = self.selectedAgent;
	if(!agent || ![_apiKeyAgentIdentifier isEqualToString:agent.identifier])
		return;

	NSString* key = [_apiKeyField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if([key isEqualToString:[AgentKeychain APIKeyForAgent:agent.identifier] ?: @""])
		return;

	NSError* error;
	if(![AgentKeychain setAPIKey:key forAgent:agent.identifier error:&error])
	{
		[[NSAlert alertWithError:error] beginSheetModalForWindow:self.view.window completionHandler:nil];
		return;
	}
	[self saveAgents]; // running panels pick up the new key for their next chat
}

// ===============
// = MCP Servers =
// ===============

- (NSView*)makeServersView
{
	NSTableColumn* enabledColumn = Column(kColumnEnabled, @"", YES, 16, NSTableColumnNoResizing);
	enabledColumn.dataCell = CheckBoxCell();
	NSTableColumn* nameColumn   = Column(kColumnName, @"Name", YES, 110, NSTableColumnUserResizingMask);
	NSTableColumn* typeColumn   = Column(kColumnType, @"Type", YES, 76, NSTableColumnNoResizing);
	NSTableColumn* targetColumn = Column(kColumnTarget, @"Command or URL", YES, 300, NSTableColumnAutoresizingMask);
	nameColumn.dataCell   = TextCell();
	targetColumn.dataCell = TextCell([NSFont userFixedPitchFontOfSize:NSFont.smallSystemFontSize + 1]);

	NSPopUpButtonCell* typeCell = [[NSPopUpButtonCell alloc] initTextCell:@"" pullsDown:NO];
	typeCell.bordered    = NO;
	typeCell.controlSize = NSControlSizeRegular;
	typeCell.font        = [NSFont systemFontOfSize:NSFont.systemFontSize];
	[typeCell addItemsWithTitles:kMCPServerTypes];
	typeColumn.dataCell = typeCell;

	NSScrollView* tableScrollView;
	_serversTableView = TableView(@[ enabledColumn, nameColumn, typeColumn, targetColumn ], self, &tableScrollView);

	NSButton* addButton;
	AddAddRemoveButtons(&addButton, &_removeServerButton, self, @selector(addServer:), @selector(removeServer:));
	_removeServerButton.enabled = NO;

	_serverVariablesLabel = OakCreateLabel(@"Environment:");
	NSScrollView* variablesScrollView = VariablesEditor(&_serverVariablesView, self);

	NSTextField* footnote = HintLabel(@"These servers are passed to every agent when a chat starts, in addition to the agent’s own MCP configuration. A stdio server runs a command (found on your login shell’s PATH); http and sse servers are reached at a URL, if the agent supports them.");
	footnote.preferredMaxLayoutWidth = 530;

	NSView* view = [[NSView alloc] initWithFrame:kTabItemFrame]; // tab items are sized by autoresizing, and nothing fits in 0×0
	NSDictionary* views = @{ @"table": tableScrollView, @"add": addButton, @"remove": _removeServerButton, @"label": _serverVariablesLabel, @"variables": variablesScrollView, @"footnote": footnote };
	OakAddAutoLayoutViewsToSuperview(views.allValues, view);
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[table]-12-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[add(==20)]-(-1)-[remove(==add)]" options:NSLayoutFormatAlignAllTop|NSLayoutFormatAlignAllBottom metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[label]-(>=12)-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[variables]-12-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[footnote]-12-|" options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-12-[table(>=60@750)]-8-[add(==19)]-12-[label]-4-[variables(==80@750)]-12-[footnote]-12-|" options:0 metrics:nil views:views]];
	return view;
}

- (AgentMCPServer*)selectedServer
{
	NSInteger row = _serversTableView.selectedRow;
	return row >= 0 && row < _servers.count ? _servers[row] : nil;
}

- (BOOL)serverUsesHeaders:(AgentMCPServer*)server
{
	return [server.type isEqualToString:@"http"] || [server.type isEqualToString:@"sse"];
}

- (void)updateServerForm
{
	AgentMCPServer* server = self.selectedServer;
	BOOL headers = [self serverUsesHeaders:server];
	_removeServerButton.enabled     = server != nil;
	_serverVariablesLabel.stringValue = headers ? @"Headers (one “Name: value” per line):" : @"Environment (one NAME=value per line):";
	_serverVariablesView.editable   = server != nil;
	_serverVariablesView.string     = server ? TextFromVariables(server.variables, headers ? @": " : @"=") : @"";
}

- (void)saveServers
{
	[AgentRegistry setMCPServers:_servers];
}

- (void)addServer:(id)sender
{
	[self commitEditing];
	AgentMCPServer* server = [[AgentMCPServer alloc] initWithDictionary:@{ @"name": [self unusedServerName], @"type": @"stdio" }];
	[_servers addObject:server];
	[self saveServers];
	[_serversTableView reloadData];
	NSInteger row = _servers.count - 1;
	[_serversTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	// The command is what a new server needs; the name has a default
	[_serversTableView editColumn:[_serversTableView columnWithIdentifier:kColumnTarget] row:row withEvent:nil select:YES];
}

- (NSString*)unusedServerName
{
	NSSet* names = [NSSet setWithArray:[_servers valueForKey:@"name"]];
	NSString* name = @"server";
	for(NSUInteger i = 2; [names containsObject:name]; ++i)
		name = [NSString stringWithFormat:@"server %lu", i];
	return name;
}

- (void)removeServer:(id)sender
{
	NSInteger row = _serversTableView.selectedRow;
	if(row < 0 || row >= _servers.count)
		return;
	if(_serversTableView.editedColumn != -1)
		[_serversTableView abortEditing];
	[_servers removeObjectAtIndex:row];
	[self saveServers];
	[_serversTableView reloadData];
	if(_servers.count)
		[_serversTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:MIN(row, (NSInteger)_servers.count - 1)] byExtendingSelection:NO];
	[self updateServerForm];
}

// =========================
// = NSTableViewDataSource =
// =========================

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
	return tableView == _agentsTableView ? _agents.count : _servers.count;
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)column row:(NSInteger)row
{
	if(tableView == _agentsTableView)
	{
		AgentDescriptor* agent = _agents[row];
		if([column.identifier isEqualToString:kColumnEnabled])
			return @(agent.enabled);
		return agent.name;
	}

	AgentMCPServer* server = _servers[row];
	if([column.identifier isEqualToString:kColumnEnabled])
		return @(server.enabled);
	if([column.identifier isEqualToString:kColumnName])
		return server.name;
	if([column.identifier isEqualToString:kColumnType])
		return @(MAX((NSInteger)[kMCPServerTypes indexOfObject:server.type], 0));
	return [self serverUsesHeaders:server] ? server.url : server.commandLine;
}

- (void)tableView:(NSTableView*)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn*)column row:(NSInteger)row
{
	if(tableView == _agentsTableView)
	{
		if([column.identifier isEqualToString:kColumnEnabled])
		{
			_agents[row].enabled = [value boolValue];
			[self saveAgents];
		}
		return;
	}

	AgentMCPServer* server = _servers[row];
	if([column.identifier isEqualToString:kColumnEnabled])
	{
		server.enabled = [value boolValue];
	}
	else if([column.identifier isEqualToString:kColumnName])
	{
		server.name = [[value description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	}
	else if([column.identifier isEqualToString:kColumnType])
	{
		NSInteger index = [value integerValue];
		if(index < 0 || index >= kMCPServerTypes.count)
			return;
		BOOL hadHeaders = [self serverUsesHeaders:server];
		server.type = kMCPServerTypes[index];
		if(hadHeaders != [self serverUsesHeaders:server])
			server.variables = @{ }; // environment variables aren’t headers
		[self updateServerForm];
	}
	else if([self serverUsesHeaders:server])
	{
		server.url = [[value description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	}
	else
	{
		server.commandLine = [[value description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	}
	[self saveServers];
}

// =======================
// = NSTableViewDelegate =
// =======================

- (void)tableView:(NSTableView*)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn*)column row:(NSInteger)row
{
	if(tableView == _serversTableView && [column.identifier isEqualToString:kColumnTarget])
		[cell setPlaceholderString:[self serverUsesHeaders:_servers[row]] ? @"https://example.com/mcp" : @"npx -y package-name"];
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification
{
	[self commitEditing];
	if(notification.object == _agentsTableView)
			[self updateAgentForm];
	else	[self updateServerForm];
}

// ============================================
// = NSTextFieldDelegate, NSTextViewDelegate =
// ============================================

- (void)controlTextDidChange:(NSNotification*)notification
{
	AgentDescriptor* agent = self.selectedAgent;
	if(!agent)
		return;

	id field = notification.object;
	if(field == _nameField)
	{
		NSString* name = [_nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if(!name.length)
			return;
		agent.name = name;
		[_agentsTableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:_agentsTableView.selectedRow] columnIndexes:[NSIndexSet indexSetWithIndex:[_agentsTableView columnWithIdentifier:kColumnName]]];
	}
	else if(field == _commandField)
	{
		agent.commandLine = [_commandField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	}
	else if(field == _apiKeyVariableField)
	{
		agent.apiKeyVariable = [_apiKeyVariableField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	}
	else
	{
		return; // the API key is saved when editing ends
	}
	[self saveAgents];
	_restoreButton.enabled = DiffersFromDefault(agent);
}

- (void)controlTextDidEndEditing:(NSNotification*)notification
{
	if(notification.object == _apiKeyField)
		[self saveAPIKey];
}

- (void)textDidChange:(NSNotification*)notification
{
	if(notification.object == _environmentView)
	{
		if(AgentDescriptor* agent = self.selectedAgent)
		{
			agent.environment = VariablesFromText(_environmentView.string, @"=");
			[self saveAgents];
			_restoreButton.enabled = DiffersFromDefault(agent);
		}
	}
	else if(notification.object == _serverVariablesView)
	{
		if(AgentMCPServer* server = self.selectedServer)
		{
			server.variables = VariablesFromText(_serverVariablesView.string, [self serverUsesHeaders:server] ? @":" : @"=");
			[self saveServers];
		}
	}
}
@end
