#import "AgentKeychain.h"
#import <Security/Security.h>

static NSString* KeychainService = @"TextMate Agent API Key";

static NSError* KeychainError (OSStatus status)
{
	NSString* message = CFBridgingRelease(SecCopyErrorMessageString(status, NULL)) ?: [NSString stringWithFormat:@"Keychain error %d", (int)status];
	return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{ NSLocalizedDescriptionKey: message }];
}

@implementation AgentKeychain
+ (NSString*)service                  { return KeychainService; }
+ (void)setService:(NSString*)service { KeychainService = [service copy]; }

+ (NSDictionary*)queryForAgent:(NSString*)identifier
{
	return @{
		(__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService: KeychainService,
		(__bridge id)kSecAttrAccount: identifier,
	};
}

+ (NSString*)APIKeyForAgent:(NSString*)identifier
{
	NSMutableDictionary* query = [[self queryForAgent:identifier] mutableCopy];
	query[(__bridge id)kSecReturnData] = @YES;
	query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

	CFTypeRef data = NULL;
	if(SecItemCopyMatching((__bridge CFDictionaryRef)query, &data) != errSecSuccess)
		return nil;
	NSString* key = [[NSString alloc] initWithData:CFBridgingRelease(data) encoding:NSUTF8StringEncoding];
	return key.length ? key : nil;
}

+ (BOOL)setAPIKey:(NSString*)key forAgent:(NSString*)identifier error:(NSError**)error
{
	NSDictionary* query = [self queryForAgent:identifier];
	if(!key.length)
	{
		OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
		if(status == errSecSuccess || status == errSecItemNotFound)
			return YES;
		if(error)
			*error = KeychainError(status);
		return NO;
	}

	NSData* data = [key dataUsingEncoding:NSUTF8StringEncoding];
	OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
	if(status == errSecItemNotFound)
	{
		NSMutableDictionary* item = [query mutableCopy];
		item[(__bridge id)kSecValueData] = data;
		item[(__bridge id)kSecAttrLabel] = [NSString stringWithFormat:@"%@ (%@)", KeychainService, identifier];
		status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
	}

	if(status != errSecSuccess && error)
		*error = KeychainError(status);
	return status == errSecSuccess;
}
@end
