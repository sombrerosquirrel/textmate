// API keys for agents, stored as generic passwords in the login Keychain
// (one per agent identifier). The methods block while the Keychain is
// accessed, so call them off the main thread where possible.

@interface AgentKeychain : NSObject
// Default: “TextMate Agent API Key”. Tests use their own.
@property (class, nonatomic, copy) NSString* service;

+ (NSString*)APIKeyForAgent:(NSString*)identifier;
// nil or empty removes the key.
+ (BOOL)setAPIKey:(NSString*)key forAgent:(NSString*)identifier error:(NSError**)error;
@end
