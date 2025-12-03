#import <Cordova/CDVPlugin.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

@interface RemoveInputAssistantPlugin : CDVPlugin <WKScriptMessageHandler>
@property (nonatomic, strong) id obsBecomeActive;
@property (nonatomic, strong) id obsWindowKey;
@property (nonatomic, assign) BOOL installed;
@end

#pragma mark - Helpers

// Helper: Recursively find the WKContentView
// This is necessary because the view hierarchy depth can change between iOS/macOS versions
static UIView* ATKFindContentView(UIView *view) {
    if ([view isKindOfClass:NSClassFromString(@"WKContentView")]) {
        return view;
    }

    for (UIView *subview in view.subviews) {
        UIView *found = ATKFindContentView(subview);
        if (found) {
            return found;
        }
    }
    return nil;
}

static inline WKWebView *ATKGetWK(RemoveInputAssistantPlugin *plugin) {
    id webView = nil;

    // cordova-ios >=6 sets engineWebView to a WKWebView
    if ([plugin.webViewEngine respondsToSelector:NSSelectorFromString(@"engineWebView")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        webView = [plugin.webViewEngine performSelector:NSSelectorFromString(@"engineWebView")];
#pragma clang diagnostic pop
    } else {
        // Fallback: many setups expose plugin.webView directly as WKWebView
        webView = plugin.webView;
    }

    return [webView isKindOfClass:[WKWebView class]] ? (WKWebView *)webView : nil;
}

static void ATKHideAssistant(WKWebView *webView) {
    if (!webView) return;

    // Ensure UI updates happen on Main Thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ATKHideAssistant(webView);
        });
        return;
    }

    // Search recursively starting from the ScrollView
    UIView *contentView = ATKFindContentView(webView.scrollView);

    if (contentView) {
        UIResponder *r = (UIResponder *)contentView;
        if ([r respondsToSelector:@selector(inputAssistantItem)]) {
            UITextInputAssistantItem *item = r.inputAssistantItem;

            // Remove the groups to hide the buttons
            item.leadingBarButtonGroups = @[];
            item.trailingBarButtonGroups = @[];

            // Ideally we also want to hide the bar entirely if empty,
            // though strict control over this varies by OS version.
            if ([item respondsToSelector:@selector(setAllowsHidingShortcuts:)]) {
                 // Common on iPad/Catalyst to allow collapsing
                 item.allowsHidingShortcuts = YES;
            }
        }
    }
}

#pragma mark - Plugin

@implementation RemoveInputAssistantPlugin

- (void)pluginInitialize {
    [super pluginInitialize];


    if(!IsiOSAppOnMac()) {
        return;
    }

    // Defer to next runloop so WKContentView exists
    dispatch_async(dispatch_get_main_queue(), ^{
        [self atk_installIfNeeded];
    });
}

- (void)atk_installIfNeeded {
    if (self.installed) return;

    WKWebView *wk = ATKGetWK(self);
    if (!wk) return;

    // JS→native bridge: re-apply on DOM focus
    WKUserContentController *ucc = wk.configuration.userContentController;
    if (ucc) {
        [ucc removeScriptMessageHandlerForName:@"__atkFocus"];
        [ucc addScriptMessageHandler:self name:@"__atkFocus"];

        NSString *js =
        @"(function(){"
        @"  if (window.__atkFocusInstalled) return; window.__atkFocusInstalled = true;"
        @"  const post = () => { try { webkit.messageHandlers.__atkFocus.postMessage(1); } catch(e){} };"
        @"  window.addEventListener('focusin', post, true);"
        @"  document.addEventListener('visibilitychange', function(){ if(!document.hidden) post(); }, true);"
        @"  setTimeout(post, 100);" // Slight delay to catch race conditions
        @"})();";

        WKUserScript *script = [[WKUserScript alloc] initWithSource:js
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                   forMainFrameOnly:NO];
        [ucc addUserScript:script];
    }

    // Apply immediately now
    ATKHideAssistant(wk);

    // Native fallbacks that actually fire on Mac
    __weak __typeof__(self) weakSelf = self;
    self.obsBecomeActive = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *n){ ATKHideAssistant(ATKGetWK(weakSelf)); }];

    self.obsWindowKey = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *n){ ATKHideAssistant(ATKGetWK(weakSelf)); }];

    self.installed = YES;
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    // Called on main thread by WebKit
    ATKHideAssistant(ATKGetWK(self));
}

#pragma mark - Lifecycle

- (void)onReset {
    // Cordova calls this on navigations; re-apply to new content
    dispatch_async(dispatch_get_main_queue(), ^{
        ATKHideAssistant(ATKGetWK(self));
    });
}

- (void)dispose {
    // Clean up when plugin is disposed (usually on app shutdown)
    if (self.obsBecomeActive) { [[NSNotificationCenter defaultCenter] removeObserver:self.obsBecomeActive]; self.obsBecomeActive = nil; }
    if (self.obsWindowKey)     { [[NSNotificationCenter defaultCenter] removeObserver:self.obsWindowKey];     self.obsWindowKey = nil; }

    WKWebView *wk = ATKGetWK(self);
    if (wk) {
        [wk.configuration.userContentController removeScriptMessageHandlerForName:@"__atkFocus"];
    }
    self.installed = NO;

    [super dispose];
}


NS_INLINE BOOL IsiOSAppOnMac(void) {
#if TARGET_OS_MACCATALYST
    return YES;
#else
    if (@available(iOS 14.0, *)) {
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        if ([pi respondsToSelector:@selector(isiOSAppOnMac)]) {
            return pi.isiOSAppOnMac;
        }
    }
    return NO;
#endif
}

@end
