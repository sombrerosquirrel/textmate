#import "AgentLog.h"

NSNotificationName const AgentLogDidChangeNotification = @"AgentLogDidChangeNotification";

@interface AgentLogEntry ()
@property (nonatomic, readwrite) NSUInteger serialNumber;
@property (nonatomic, readwrite) NSDate* date;
@property (nonatomic, readwrite) NSString* source;
@property (nonatomic, readwrite) AgentLogEntryKind kind;
@property (nonatomic, readwrite) NSDictionary* message;
@property (nonatomic, readwrite) NSString* text;
@end

@implementation AgentLogEntry
{
	NSString* _json;
}

- (NSString*)summary
{
	if(_kind == AgentLogEntryKindStandardError)
		return @"stderr";
	if(_kind == AgentLogEntryKindEvent)
		return _text;

	NSString* arrow = _kind == AgentLogEntryKindSent ? @"→" : @"←";
	id identifier = _message[@"id"];
	NSString* method = [_message[@"method"] isKindOfClass:[NSString class]] ? _message[@"method"] : nil;
	if(!method)
		return [NSString stringWithFormat:@"%@ %@ #%@", arrow, _message[@"error"] ? @"error" : @"result", identifier];

	NSMutableString* res = [NSMutableString stringWithFormat:@"%@ %@", arrow, method];
	NSDictionary* params = [_message[@"params"] isKindOfClass:[NSDictionary class]] ? _message[@"params"] : nil;
	NSDictionary* update = [params[@"update"] isKindOfClass:[NSDictionary class]] ? params[@"update"] : nil;
	if([update[@"sessionUpdate"] isKindOfClass:[NSString class]])
		[res appendFormat:@" %@", update[@"sessionUpdate"]];
	if(identifier)
		[res appendFormat:@" #%@", identifier];
	return res;
}

- (NSString*)json
{
	if(!_json && _message)
	{
		NSData* data = [NSJSONSerialization dataWithJSONObject:_message options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil];
		_json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : _message.description;
	}
	return _json;
}

- (NSString*)detailWithLimit:(NSUInteger)limit
{
	NSString* detail = _message ? self.json : (_kind == AgentLogEntryKindStandardError ? _text : nil);
	if(limit && detail.length > limit)
		return [NSString stringWithFormat:@"%@… (%lu more characters)", [detail substringToIndex:[detail rangeOfComposedCharacterSequenceAtIndex:limit].location], detail.length - limit];
	return detail;
}

- (BOOL)matchesSearchString:(NSString*)searchString
{
	if(!searchString.length)
		return YES;
	return [self.summary localizedCaseInsensitiveContainsString:searchString] || [[self detailWithLimit:0] localizedCaseInsensitiveContainsString:searchString] || [_source localizedCaseInsensitiveContainsString:searchString];
}
@end

@implementation AgentLog
{
	NSMutableArray<AgentLogEntry*>* _entries;
	NSMutableArray<NSString*>* _sources;
	NSUInteger _nextSerialNumber;
	BOOL _notificationPending;
}

+ (AgentLog*)sharedLog
{
	static AgentLog* sharedLog = [[self alloc] init];
	return sharedLog;
}

- (instancetype)init
{
	if(self = [super init])
	{
		_entries        = [NSMutableArray array];
		_sources        = [NSMutableArray array];
		_maximumEntries = 5000;
	}
	return self;
}

- (NSArray<AgentLogEntry*>*)entries { return _entries; }
- (NSArray<NSString*>*)sources      { return _sources; }

- (void)addEntryWithKind:(AgentLogEntryKind)kind message:(NSDictionary*)message text:(NSString*)text source:(NSString*)source
{
	AgentLogEntry* entry = [[AgentLogEntry alloc] init];
	entry.serialNumber = ++_nextSerialNumber;
	entry.date         = [NSDate date];
	entry.source       = source ?: @"Agent";
	entry.kind         = kind;
	entry.message      = message;
	entry.text         = text;
	[_entries addObject:entry];

	if(![_sources containsObject:entry.source])
		[_sources addObject:entry.source];

	// Trim in batches so a busy log doesn’t shift the array on every entry
	NSUInteger slack = MAX(_maximumEntries / 10, 1);
	if(_entries.count > _maximumEntries + slack)
		[_entries removeObjectsInRange:NSMakeRange(0, _entries.count - _maximumEntries)];

	[self postChangeNotification];
}

- (void)addMessage:(NSDictionary*)message outgoing:(BOOL)outgoing source:(NSString*)source
{
	[self addEntryWithKind:(outgoing ? AgentLogEntryKindSent : AgentLogEntryKindReceived) message:message text:nil source:source];
}

- (void)addStandardError:(NSString*)text source:(NSString*)source
{
	text = [text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	if(text.length)
		[self addEntryWithKind:AgentLogEntryKindStandardError message:nil text:text source:source];
}

- (void)addEvent:(NSString*)text source:(NSString*)source
{
	[self addEntryWithKind:AgentLogEntryKindEvent message:nil text:text source:source];
}

- (void)clear
{
	[_entries removeAllObjects];
	[self postChangeNotification];
}

// Agents stream replies in many small messages; one notification per run loop cycle is enough
- (void)postChangeNotification
{
	if(_notificationPending)
		return;
	_notificationPending = YES;
	dispatch_async(dispatch_get_main_queue(), ^{
		_notificationPending = NO;
		[NSNotificationCenter.defaultCenter postNotificationName:AgentLogDidChangeNotification object:self];
	});
}
@end
