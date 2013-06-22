#import <Cocoa/Cocoa.h>

#import "TFStandardVersionComparator.h"

#define EXPORT __attribute__((visibility("default")))

#define WAIT_FOR_APPLE_EVENT_TO_ENTER_HANDLER_IN_SECONDS 1.0
#define TOTALFINDER_STANDARD_INSTALL_LOCATION "/Applications/TotalFinder.app"
#define HOMEPAGE_URL @"http://totalfinder.binaryage.com"
#define FINDER_MIN_TESTED_VERSION @"10.7.0"
#define FINDER_MAX_TESTED_VERSION @"10.8.4"
#define FINDER_UNSUPPORTED_VERSION @"10.9"
#define TOTALFINDER_INJECTED_NOTIFICATION @"TotalFinderInjectedNotification"

EXPORT OSErr HandleInitEvent(const AppleEvent* ev, AppleEvent* reply, long refcon);

static NSString* globalLock = @"I'm the global lock to prevent concruent handler executions";
static bool enteredHandler = false;
static bool totalFinderAlreadyLoaded = false;

// Imagine this code:
//
//    NSString* source = @"tell application \"Finder\" to «event BATFinit»";
//    NSAppleScript* appleScript = [[NSAppleScript alloc] initWithSource:source];
//    [appleScript executeAndReturnError:nil];
//
// Force-quit Finder.app, wait for plain Finder.app to be relaunched by launchd, execute this code...
//
// On my machine (OS X 10.8.4-12E55) it sends following 4 events to the Finder process:
//
//    aevt('BATF'\'init' transactionID=0 returnID=29128 sourcePSN=[0x0,202202 "Finder"] timeout=7200 eventSource=3 { &'subj':null(), &'csig':magn(65536) })
//    aevt('ascr'\'gdut' transactionID=0 returnID=23693 sourcePSN=[0x0,202202 "Finder"] timeout=7200 eventSource=3 {  })
//    aevt('BATF'\'init' transactionID=0 returnID=29128 sourcePSN=[0x0,202202 "Finder"] timeout=7200 eventSource=3 { &'subj':null(), &'csig':magn(65536) })
//    aevt('BATF'\'init' transactionID=0 returnID=29128 sourcePSN=[0x0,202202 "Finder"] timeout=7200 eventSource=3 { &'subj':null(), &'csig':magn(65536), &'autx':autx('autx'(368CEB26DFB7FE807CA5860100000000000000000000000000000000000000000036)) })
//
//
// My explanation (pure speculation):
//
// 1. First, it naively fails (-1708)
// 2. Then it tries to load dynamic additions (http://developer.apple.com/library/mac/#qa/qa1070/_index.html)
// 3. Then it tries again but fails because the Finder requires "signature" (-10004)
// 4. Finally it signs the event, sends it again and it succeeds
//
// Ok, this works, so why do we need a better solution?
//
//   quite some people have had troubles injecting TotalFinder during startup using applescript.
//   I don't know what is wrong with their machines or applescript subsystem, but they were getting:
//   "Connection is Invalid -609" or "The operation couldn’t be completed -1708" or some other mysterious applescript error codes.
//
// Here are several possible scenarios:
//
//   1. system is busy, Finder process is busy or applescriptd is busy => timeout
//   2. Finder crashed during startup, got (potentially) restarted, but applescript subsystem caches handle and is unable to deliver events
//   3. our script is too fast and finished launching before Finder.app itself entered main loop => unexpected timing errors
//   4. some other similar issue
//
// A more robust solution?
//
//   1. Don't use high-level applescript. Send raw events using lowest level API available (AESendMessage).
//   2. Don't deal with timeouts, don't wait for replies and don't process errors.
//   3. Wait for Finder.app to fully launch.
//   4. Try multiple times.
//   5. Enable excessive debug logging for troubleshooting
//
// Sounds good, where is the problem?
// The problem is that sending raw apple events is hard and I don't know how to sign them (have any docs on csig, autx?).
// Observation: They don't get delivered, but OSAX gets loaded into app's address space.
// Solution: use a trick __attribute__((constructor)) enabled by complexities of C++ runtime:
// this code is executed early every time our binary is loaded into Finder's address space
// even if the event later fails to be delivered into HandleInitEvent because of some (security) reasons
//

static void broadcastSucessfulInjection() {
  pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
  [[NSDistributedNotificationCenter defaultCenter]postNotificationName:TOTALFINDER_INJECTED_NOTIFICATION
                                                                object:[[NSBundle mainBundle]bundleIdentifier]
                                                              userInfo:@{@"pid": @(pid)}];
}
__attribute__((constructor))
static void autoInitializer() {
  enteredHandler = false;
  dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(WAIT_FOR_APPLE_EVENT_TO_ENTER_HANDLER_IN_SECONDS * NSEC_PER_SEC));
  // dispatch_after is here for backward compatibility (e.g. someone could use AppleScript Editor or command-line to inject TotalFinder),
  // we give applescript subsystem some time to do its work and enter some handler
  // if it fails, we assume init event was requested and execute HandleInitEvent
  dispatch_after(delay, dispatch_get_main_queue(), ^(void) {
    if (enteredHandler) {
      return; // applescript subsystem was able to execute one of our handlers, nothing to do
    }
    AppleEvent err;
    AECreateAppleEvent('BATF', 'err-', NULL, kAutoGenerateReturnID, kAnyTransactionID, &err);
    HandleInitEvent(NULL, &err, 0);
    AEDisposeDesc(&err);
  });
}

// SIMBL-compatible interface
@interface TotalFinderShell : NSObject { }
-(void) install;
-(void) crashMe;
@end

// just a dummy class for locating our bundle
@interface TotalFinderInjector : NSObject { }
@end

@implementation TotalFinderInjector { }
@end

typedef struct {
  NSString* location;
} configuration;

static OSErr AEPutParamString(AppleEvent* event, AEKeyword keyword, NSString* string) {
  UInt8* textBuf;
  CFIndex length, maxBytes, actualBytes;

  length = CFStringGetLength((CFStringRef)string);
  maxBytes = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8);
  textBuf = malloc(maxBytes);
  if (textBuf) {
    CFStringGetBytes((CFStringRef)string, CFRangeMake(0, length), kCFStringEncodingUTF8, 0, true, (UInt8*)textBuf, maxBytes, &actualBytes);
    OSErr err = AEPutParamPtr(event, keyword, typeUTF8Text, textBuf, actualBytes);
    free(textBuf);
    return err;
  } else {
    return memFullErr;
  }
}

static void reportError(AppleEvent* reply, NSString* msg) {
  NSLog(@"TotalFinderInjector: %@", msg);
  AEPutParamString(reply, keyErrorString, msg);
}

EXPORT OSErr HandleInitEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  enteredHandler = true;
  @synchronized(globalLock) {
    @autoreleasepool {
      NSBundle* injectorBundle = [NSBundle bundleForClass:[TotalFinderInjector class]];
      NSString* injectorVersion = [injectorBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
      
      if (!injectorVersion || ![injectorVersion isKindOfClass:[NSString class]]) {
        reportError(reply, [NSString stringWithFormat:@"Unable to determine TotalFinderInjector version!"]);
        return 7;
      }
      
      NSLog(@"TotalFinderInjector v%@ received init event", injectorVersion);
      
      NSString* bundleName = @"TotalFinder";
      NSString* targetAppName = @"Finder";
      NSString* supressKey = @"TotalFinderSuppressFinderVersionCheck";
      NSString* maxVersion = FINDER_MAX_TESTED_VERSION;
      NSString* minVersion = FINDER_MIN_TESTED_VERSION;
      
      if (totalFinderAlreadyLoaded) {
        NSLog(@"TotalFinderInjector: %@ has been already loaded. Ignoring this request.", bundleName);
        return noErr;
      }
      
      @try {
        NSBundle* mainBundle = [NSBundle mainBundle];
        if (!mainBundle) {
          reportError(reply, [NSString stringWithFormat:@"Unable to locate main %@ bundle!", targetAppName]);
          return 4;
        }
        
        NSString* mainVersion = [mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (!mainVersion || ![mainVersion isKindOfClass:[NSString class]]) {
          reportError(reply, [NSString stringWithFormat:@"Unable to determine %@ version!", targetAppName]);
          return 5;
        }
        
        // some future versions are explicitely unsupported
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        if (![defaults boolForKey:supressKey]) {
          if ([mainVersion rangeOfString:FINDER_UNSUPPORTED_VERSION].length > 0) {
            NSAlert* alert = [NSAlert new];
            [alert setMessageText:[NSString stringWithFormat:@"You have %@ version %@", targetAppName, mainVersion]];
            [alert setInformativeText:[NSString stringWithFormat:@"But this version of TotalFinder wasn't tested with new OS X 10.9.\n\nYou may expect a new TotalFinder release soon.\nPlease visit totalfinder.binaryage.com for more info."]];
            [alert setShowsSuppressionButton:YES];
            [alert addButtonWithTitle:@"Cancel and visit the website"];
            [alert addButtonWithTitle:@"Launch TotalFinder anyway"];
            NSInteger res = [alert runModal];
            if ([[alert suppressionButton] state] == NSOnState) {
              [defaults setBool:YES forKey:supressKey];
            }
            if (res == NSAlertFirstButtonReturn) {
              [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:HOMEPAGE_URL]];
              // cancel
              return noErr;
            }
          }
        }
        
        // warn about non-tested minor versions into the log only
        TFStandardVersionComparator* comparator = [TFStandardVersionComparator defaultComparator];
        if (([comparator compareVersion:mainVersion toVersion:maxVersion] == NSOrderedDescending) ||
            ([comparator compareVersion:mainVersion toVersion:minVersion] == NSOrderedAscending)) {
          NSLog(@"You have %@ version %@. But %@ was properly tested only with %@ versions in range %@ - %@.", targetAppName, mainVersion, bundleName, targetAppName, minVersion, maxVersion);
        }
        
        NSBundle* totalFinderInjectorBundle = [NSBundle bundleForClass:[TotalFinderInjector class]];
        NSString* totalFinderLocation = [totalFinderInjectorBundle pathForResource:bundleName ofType:@"bundle"];
        NSBundle* pluginBundle = [NSBundle bundleWithPath:totalFinderLocation];
        if (!pluginBundle) {
          reportError(reply, [NSString stringWithFormat:@"Unable to create bundle from path: %@ [%@]", totalFinderLocation, totalFinderInjectorBundle]);
          return 2;
        }
        
        NSError* error;
        if (![pluginBundle loadAndReturnError:&error]) {
          reportError(reply, [NSString stringWithFormat:@"Unable to load bundle from path: %@ error: %@", totalFinderLocation, [error localizedDescription]]);
          return 6;
        }
        Class principalClass = [pluginBundle principalClass];
        if (!principalClass) {
          reportError(reply, [NSString stringWithFormat:@"Unable to retrieve principalClass for bundle: %@", pluginBundle]);
          return 3;
        }
        id principalClassObject = NSClassFromString(NSStringFromClass(principalClass));
        if ([principalClassObject respondsToSelector:@selector(install)]) {
          NSLog(@"TotalFinderInjector: Installing %@ ...", bundleName);
          [principalClassObject install];
        }
        
        totalFinderAlreadyLoaded = true;
        broadcastSucessfulInjection();
        
        return noErr;
      } @catch (NSException* exception) {
        reportError(reply, [NSString stringWithFormat:@"Failed to load %@ with exception: %@", bundleName, exception]);
      }
      
      return 1;
    }
  }
}

EXPORT OSErr HandleCheckEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  enteredHandler = true;
  @synchronized(globalLock) {
    @autoreleasepool {
      if (totalFinderAlreadyLoaded) {
        return noErr;
      }

      reportError(reply, @"TotalFinder not loaded");
      return 1;
    }
  }
}

// debug command to emulate a crash in our code
EXPORT OSErr HandleCrashEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  enteredHandler = true;
  @synchronized(globalLock) {
    @autoreleasepool {
      if (!totalFinderAlreadyLoaded) {
        return 1;
      }

      TotalFinderShell* shell = [NSClassFromString(@"TotalFinder") sharedInstance];
      if (!shell) {
        reportError(reply, [NSString stringWithFormat:@"Unable to retrieve shell class"]);
        return 3;
      }

      [shell crashMe];
    }
  }
}
