#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

static SPUStandardUpdaterController *tokenTachUpdater;

static void startUpdater(void) {
    if (tokenTachUpdater != nil) return;

    NSBundle *bundle = NSBundle.mainBundle;
    NSString *feedURL = [bundle objectForInfoDictionaryKey:@"SUFeedURL"];
    NSString *publicKey = [bundle objectForInfoDictionaryKey:@"SUPublicEDKey"];
    if (feedURL.length == 0 || publicKey.length == 0) {
        NSLog(@"Token Tach updater disabled: signed-feed configuration is missing");
        return;
    }

    tokenTachUpdater = [[SPUStandardUpdaterController alloc]
        initWithStartingUpdater:YES
        updaterDelegate:nil
        userDriverDelegate:nil];
}

void token_tach_updater_start(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ startUpdater(); });
}

void token_tach_updater_check(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        startUpdater();
        [tokenTachUpdater checkForUpdates:nil];
    });
}
