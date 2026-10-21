// Opens a URL on the simulator it runs in, with the privilege SpringBoard gives Settings links.
// `simctl openurl` refuses those, and on iOS 26.5 tapping General › Keyboard in Settings shows a
// blank page, so a deep link is the only way to reach some pages.
//
// The app ships this source and builds it for the simulator on first use, with the selected Xcode
// (see Sources/SimulatorCore/SensitiveURL.swift), then runs it with
// `simctl spawn <udid> open-sensitive-url <url>`. The guest reads its entitlement from the
// `__entitlements` section, as it does for apps Xcode builds for the simulator.

#import <Foundation/Foundation.h>
#import <objc/message.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: open-sensitive-url <url>\n");
            return 64;
        }
        NSURL *url = [NSURL URLWithString:@(argv[1])];
        if (!url) {
            fprintf(stderr, "Not a valid URL: %s\n", argv[1]);
            return 64;
        }

        // Private API: checked first, so a renamed selector fails with a message instead of a crash.
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        SEL defaultWorkspace = NSSelectorFromString(@"defaultWorkspace");
        SEL openSensitive = NSSelectorFromString(@"openSensitiveURL:withOptions:error:");
        id workspace = [workspaceClass respondsToSelector:defaultWorkspace]
            ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultWorkspace)
            : nil;
        if (![workspace respondsToSelector:openSensitive]) {
            fprintf(stderr, "This iOS version can't open Settings links.\n");
            return 69;
        }

        NSError *error = nil;
        BOOL opened = ((BOOL (*)(id, SEL, NSURL *, NSDictionary *, NSError **))objc_msgSend)(
            workspace, openSensitive, url, nil, &error);
        if (!opened) {
            fprintf(stderr, "%s\n", (error.localizedDescription ?: @"The link couldn't be opened.").UTF8String);
            return 1;
        }
    }
    return 0;
}
