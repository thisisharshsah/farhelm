// Companion's door to Chromium (CEF, the Chromium Embedded Framework),
// in plain Objective-C so Swift can use it. The C++ stays in CEFKit.mm.
//
// Each browser is a Chrome-style CEF browser (Chrome's own extension
// system, Web Store, toolbar and popups) in a frameless window that
// Companion keeps exactly over its browser pane. CEF on macOS runs the
// basic "Alloy" style for any browser placed inside another view, and
// Alloy has no Chrome extensions; a window of its own is how Chrome style
// is kept.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The app's NSApplication (Info.plist NSPrincipalClass). Chromium needs
/// to know when the app is sending an event, and to shut down in order on
/// quit.
@interface CEFApplication : NSApplication
@end

@class ChromiumBrowser;

@protocol ChromiumBrowserDelegate <NSObject>
- (void)chromiumBrowser:(ChromiumBrowser *)browser didChangeTitle:(NSString *)title;
- (void)chromiumBrowser:(ChromiumBrowser *)browser didChangeURL:(NSString *)url;
- (void)chromiumBrowser:(ChromiumBrowser *)browser
       didChangeLoading:(BOOL)loading
              canGoBack:(BOOL)canGoBack
           canGoForward:(BOOL)canGoForward;
/// A page or extension opened a new window: it arrives as its own browser.
- (void)chromiumBrowser:(ChromiumBrowser *)browser didOpenPopup:(ChromiumBrowser *)popup;
- (void)chromiumBrowserDidClose:(ChromiumBrowser *)browser;
@optional
/// A page called a binding added with -addBinding: (DevTools
/// Runtime.bindingCalled), with the string it passed.
- (void)chromiumBrowser:(ChromiumBrowser *)browser didCallBinding:(NSString *)name payload:(NSString *)payload;
@end

@interface Chromium : NSObject
/// Built with CEF and the framework is inside the app.
@property (class, readonly) BOOL isAvailable;
/// Started (once). Its profile (sign-ins, extensions, history) lives in
/// `profileDirectory`.
+ (BOOL)startWithProfileDirectory:(NSString *)profileDirectory;
@property (class, readonly) BOOL isRunning;
/// Started and ready for browsers. Chromium finishes starting a moment
/// after +startWithProfileDirectory: returns; a browser made before then
/// stops the app.
@property (class, readonly) BOOL isReady;
/// Runs `block` once Chromium is ready (at once if it is).
+ (void)whenReady:(void (^)(void))block;
/// Where Chromium writes what went wrong (warnings and errors).
@property (class, readonly, copy) NSString *logPath;
@property (class, readonly, copy) NSString *lastError;
/// The version of Chromium inside, for Settings.
@property (class, readonly, copy) NSString *chromiumVersion;
/// A window Chromium opened on its own (a restored session, an extension's
/// chrome.windows.create, "Open in New Window") is closed, and its page
/// handed here to open as a tab in Companion's browser.
@property (class, copy, nullable) void (^strayPageHandler)(NSString *url);
@end

@interface ChromiumBrowser : NSObject
- (nullable instancetype)initWithURL:(NSString *)url delegate:(id<ChromiumBrowserDelegate>)delegate;
@property (nonatomic, weak, nullable) id<ChromiumBrowserDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *url;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) BOOL loading;

/// Shows it over `parent`, filling `screenFrame` (screen coordinates),
/// moving with the parent.
- (void)showAbove:(NSWindow *)parent frame:(NSRect)screenFrame NS_SWIFT_NAME(show(above:frame:));
- (void)hide;

/// The page's corners, rounded to sit in a rounded panel. 0, the usual,
/// leaves them square.
@property (nonatomic) CGFloat cornerRadius;

- (void)load:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)close;

/// Whether the page is there to talk to (it is created a moment after
/// the browser).
@property (nonatomic, readonly) BOOL ready;

/// Runs a script in every page from now on, before the page's own, and
/// in the page showing now.
- (void)addScriptOnNewDocument:(NSString *)source NS_SWIFT_NAME(addScriptOnNewDocument(_:));

/// A function `name(string)` in every page that reaches the delegate's
/// -chromiumBrowser:didCallBinding:payload:.
- (void)addBinding:(NSString *)name;

/// Runs JavaScript in the page (DevTools Runtime.evaluate, awaiting a
/// promise, the value returned as JSON). The completion gets the DevTools
/// result as JSON text, or an error.
- (void)evaluate:(NSString *)expression
      completion:(void (^)(NSString *_Nullable json, NSString *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
