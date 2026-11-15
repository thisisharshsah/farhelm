// Companion's Chromium: CEF in Chrome style, one frameless window per tab
// kept over the browser pane. Built only when CEF is in Vendor/cef
// (scripts/fetch-cef.sh); otherwise these are stubs that say Chromium is
// not there, and Companion uses its WebKit browser.

#import "CEFKit.h"
#import <QuartzCore/QuartzCore.h>

#if __has_include("include/cef_app.h")
#define COMPANION_CEF 1
#include <crt_externs.h>
#include <algorithm>
#include <map>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_request_context.h"
#include "include/cef_values.h"
#include "include/cef_version.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_library_loader.h"
#endif

static NSString *const kFrameworkName = @"Chromium Embedded Framework.framework";
static NSString *const kHelperPath = @"Companion Helper.app/Contents/MacOS/Companion Helper";

#if COMPANION_CEF

@interface ChromiumBrowser ()
- (instancetype)initWithPopupView:(CefRefPtr<CefBrowserView>)view delegate:(id<ChromiumBrowserDelegate>)delegate;
- (CefRefPtr<CefBrowser>)cefBrowser;
- (void)cefTitle:(NSString *)title;
- (void)cefURL:(NSString *)url;
- (void)cefLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward;
- (void)cefClosed;
- (void)cefResult:(int)messageID ok:(BOOL)ok json:(NSString *)json;
- (void)cefEvent:(NSString *)method json:(NSString *)json;
@end

namespace {

bool gRunning = false;
bool gReady = false;
NSMutableArray<void (^)(void)> *gWaiting = nil;
NSString *gLogPath = @"";
bool gPumping = false;
NSString *gError = @"";
CefScopedLibraryLoader *gLoader = nullptr;
NSMutableSet<ChromiumBrowser *> *gBrowsers = nil;
NSTimer *gTimer = nil;
int gNextMessage = 1;
void (^gStrayHandler)(NSString *) = nil;

/// The client for browsers Chromium makes on its own (defined below).
CefRefPtr<CefClient> DefaultClient();

void Pump() {
  if (!gRunning || gPumping) return;
  gPumping = true;
  CefDoMessageLoopWork();
  gPumping = false;
}

NSString *Str(const CefString &value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

/// The Companion browser a CEF browser belongs to.
ChromiumBrowser *Owner(CefRefPtr<CefBrowser> browser) {
  if (!browser) return nil;
  for (ChromiumBrowser *candidate in gBrowsers) {
    CefRefPtr<CefBrowser> mine = [candidate cefBrowser];
    if (mine && mine->IsSame(browser)) return candidate;
  }
  return nil;
}

/// CEF's handle for a window is an NSView or an NSWindow, depending on the
/// version; both come back as the NSWindow.
NSWindow *WindowOf(id handle) {
  if ([handle isKindOfClass:[NSWindow class]]) return handle;
  if ([handle isKindOfClass:[NSView class]]) return [(NSView *)handle window];
  return nil;
}
NSWindow *WindowOf(void *handle) { return handle ? WindowOf((__bridge id)handle) : nil; }

/// Rounds the corners of a page's window, so it sits in a rounded panel
/// the way the panel's own content does. The window is made see-through
/// where the corners are cut away; this is asked again each time the
/// window is placed, in case Chromium has set it back.
static void RoundCorners(NSWindow *window, CGFloat radius) {
  NSView *content = window.contentView;
  if (!content || radius <= 0) return;
  if (window.opaque) {
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
  }
  content.wantsLayer = YES;
  CALayer *layer = content.layer;
  if (!layer) return;
  if (layer.cornerRadius != radius || !layer.masksToBounds) {
    layer.cornerRadius = radius;
    layer.cornerCurve = @"continuous";
    layer.masksToBounds = YES;
  }
}

class CompanionApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  // Windows Chromium opens itself come to Companion's client, so they are
  // seen and turned into tabs.
  CefRefPtr<CefClient> GetDefaultClient() override { return DefaultClient(); }

  // Chromium asks for its work to be run; the timer runs it too.
  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    int64_t delay = std::max<int64_t>(0, std::min<int64_t>(delay_ms, 33));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      Pump();
    });
  }

  // Chromium is ready for browsers: whatever waited for it goes now.
  void OnContextInitialized() override {
    gReady = true;
    // Companion keeps its own tabs; Chrome does not bring back its windows
    // from last time (5: open the new tab page).
    CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
    if (context) {
      CefRefPtr<CefValue> value = CefValue::Create();
      value->SetInt(5);
      CefString error;
      context->SetPreference("session.restore_on_startup", value, error);
    }
    NSArray<void (^)(void)> *waiting = [gWaiting copy];
    [gWaiting removeAllObjects];
    for (void (^block)(void) in waiting) block();
  }

 private:
  IMPLEMENT_REFCOUNTING(CompanionApp);
};

class Client : public CefClient,
               public CefDisplayHandler,
               public CefLifeSpanHandler,
               public CefLoadHandler,
               public CefDevToolsMessageObserver {
 public:
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &url) override {
    if (frame && frame->IsMain()) [Owner(browser) cefURL:Str(url)];
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    [Owner(browser) cefTitle:Str(title)];
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override {
    [Owner(browser) cefLoading:isLoading back:canGoBack forward:canGoForward];
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    [Owner(browser) cefClosed];
  }

  // Every browser of Companion's is known by now or a moment later; one
  // that is not was opened by Chromium itself, in a window of Chrome's.
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { CheckStray(browser, 0); }

  static void CheckStray(CefRefPtr<CefBrowser> browser, int tries) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      if (!gRunning || !browser->IsValid() || Owner(browser)) return;
      CefRefPtr<CefFrame> frame = browser->GetMainFrame();
      NSString *url = frame ? Str(frame->GetURL()) : @"";
      // Its page may not be set yet; look again for a couple of seconds.
      if (url.length == 0 && tries < 8) {
        CheckStray(browser, tries + 1);
        return;
      }
      browser->GetHost()->CloseBrowser(true);
      if (url.length && ![url isEqualToString:@"about:blank"] && ![url hasPrefix:@"chrome://newtab"] && gStrayHandler) {
        gStrayHandler(url);
      }
    });
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success,
                              const void *result, size_t result_size) override {
    NSString *json = [[NSString alloc] initWithBytes:result length:result_size encoding:NSUTF8StringEncoding] ?: @"";
    [Owner(browser) cefResult:message_id ok:success json:json];
  }

  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString &method,
                       const void *params, size_t params_size) override {
    NSString *json = [[NSString alloc] initWithBytes:params length:params_size encoding:NSUTF8StringEncoding] ?: @"";
    [Owner(browser) cefEvent:Str(method) json:json];
  }

 private:
  IMPLEMENT_REFCOUNTING(Client);
};

class ViewDelegate : public CefBrowserViewDelegate {
 public:
  // No Chrome toolbar: Companion's own bar drives the page.
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView> browser_view) override { return CEF_CTT_NONE; }
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }

  // A new window from a page or an extension becomes a tab in Companion.
  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> browser_view,
                                 CefRefPtr<CefBrowserView> popup_browser_view,
                                 bool is_devtools) override {
    ChromiumBrowser *opener = Owner(browser_view->GetBrowser());
    id<ChromiumBrowserDelegate> delegate = opener.delegate;
    if (!opener || !delegate || is_devtools) return false;
    ChromiumBrowser *popup = [[ChromiumBrowser alloc] initWithPopupView:popup_browser_view delegate:delegate];
    if (!popup) return false;
    [delegate chromiumBrowser:opener didOpenPopup:popup];
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(ViewDelegate);
};

class WindowDelegate : public CefWindowDelegate {
 public:
  explicit WindowDelegate(CefRefPtr<CefBrowserView> view) : view_(view) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override { window->AddChildView(view_); }
  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override { view_ = nullptr; }
  bool IsFrameless(CefRefPtr<CefWindow> window) override { return true; }
  bool CanMaximize(CefRefPtr<CefWindow> window) override { return false; }
  // The pane sets its size and place; it is never dragged or resized itself.
  bool CanResize(CefRefPtr<CefWindow> window) override { return false; }
  bool CanMinimize(CefRefPtr<CefWindow> window) override { return false; }
  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow> window) override { return CEF_SHOW_STATE_HIDDEN; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  CefSize GetPreferredSize(CefRefPtr<CefView> view) override { return CefSize(900, 700); }

  bool CanClose(CefRefPtr<CefWindow> window) override {
    CefRefPtr<CefBrowser> browser = view_ ? view_->GetBrowser() : nullptr;
    return browser ? browser->GetHost()->TryCloseBrowser() : true;
  }

 private:
  CefRefPtr<CefBrowserView> view_;
  IMPLEMENT_REFCOUNTING(WindowDelegate);
};

CefRefPtr<CompanionApp> gApp;
CefRefPtr<Client> gClient;
CefRefPtr<ViewDelegate> gViewDelegate;

CefRefPtr<CefClient> DefaultClient() { return gClient; }

}  // namespace

#endif  // COMPANION_CEF

// MARK: - The application

#if COMPANION_CEF
@interface CEFApplication () <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end
#endif

@implementation CEFApplication

#if COMPANION_CEF
- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEvent;
  [super sendEvent:event];
}

/// Chromium closes its browsers and shuts down before the app goes.
- (void)terminate:(id)sender {
  if (gRunning) {
    for (ChromiumBrowser *browser in [gBrowsers copy]) {
      CefRefPtr<CefBrowser> cef = [browser cefBrowser];
      if (cef) cef->GetHost()->CloseBrowser(true);
    }
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2];
    while (gBrowsers.count > 0 && [end timeIntervalSinceNow] > 0) {
      CefDoMessageLoopWork();
      usleep(10000);
    }
    [gTimer invalidate];
    gTimer = nil;
    gClient = nullptr;
    gViewDelegate = nullptr;
    CefShutdown();
    gRunning = false;
  }
  [super terminate:sender];
}
#endif

@end

// MARK: - Chromium

@implementation Chromium

+ (BOOL)isAvailable {
#if COMPANION_CEF
  NSString *framework = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks"]
      stringByAppendingPathComponent:kFrameworkName];
  return [NSFileManager.defaultManager fileExistsAtPath:framework];
#else
  return NO;
#endif
}

+ (BOOL)isReady {
#if COMPANION_CEF
  return gReady;
#else
  return NO;
#endif
}

+ (void)whenReady:(void (^)(void))block {
#if COMPANION_CEF
  if (gReady) {
    block();
    return;
  }
  if (!gWaiting) gWaiting = [NSMutableArray array];
  [gWaiting addObject:[block copy]];
#endif
}

+ (NSString *)logPath {
#if COMPANION_CEF
  return gLogPath;
#else
  return @"";
#endif
}

+ (BOOL)isRunning {
#if COMPANION_CEF
  return gRunning;
#else
  return NO;
#endif
}

+ (NSString *)lastError {
#if COMPANION_CEF
  return gError;
#else
  return @"Companion was built without Chromium. Run bash build.sh to fetch it.";
#endif
}

+ (NSString *)chromiumVersion {
#if COMPANION_CEF
  return @(CEF_VERSION);
#else
  return @"";
#endif
}

+ (void (^)(NSString *))strayPageHandler {
#if COMPANION_CEF
  return gStrayHandler;
#else
  return nil;
#endif
}

+ (void)setStrayPageHandler:(void (^)(NSString *))handler {
#if COMPANION_CEF
  gStrayHandler = [handler copy];
#endif
}

+ (BOOL)startWithProfileDirectory:(NSString *)profileDirectory {
#if COMPANION_CEF
  if (gRunning) return YES;
  if (!self.isAvailable) {
    gError = @"Chromium is not inside this build of Companion.";
    return NO;
  }
  if (![NSApp conformsToProtocol:@protocol(CefAppProtocol)]) {
    gError = @"Companion's Info.plist must name CEFApplication as its principal class.";
    return NO;
  }
  if (!gLoader) {
    gLoader = new CefScopedLibraryLoader();
    if (!gLoader->LoadInMain()) {
      delete gLoader;
      gLoader = nullptr;
      gError = @"Chromium's framework could not be loaded.";
      return NO;
    }
  }
  [NSFileManager.defaultManager createDirectoryAtPath:profileDirectory
                          withIntermediateDirectories:YES attributes:nil error:nil];

  NSString *bundle = NSBundle.mainBundle.bundlePath;
  NSString *frameworks = [bundle stringByAppendingPathComponent:@"Contents/Frameworks"];
  CefSettings settings;
  settings.no_sandbox = true;
  settings.external_message_pump = true;
  settings.persist_session_cookies = true;
  // What goes wrong is written down, next to the profile.
  gLogPath = [[profileDirectory stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"chromium.log"];
  CefString(&settings.log_file) = gLogPath.UTF8String;
  settings.log_severity = LOGSEVERITY_WARNING;
  CefString(&settings.browser_subprocess_path) = [frameworks stringByAppendingPathComponent:kHelperPath].UTF8String;
  CefString(&settings.framework_dir_path) = [frameworks stringByAppendingPathComponent:kFrameworkName].UTF8String;
  CefString(&settings.main_bundle_path) = bundle.UTF8String;
  // One profile, kept: sign-ins, extensions and history stay, as in Chrome.
  CefString(&settings.root_cache_path) = profileDirectory.UTF8String;
  CefString(&settings.cache_path) = [profileDirectory stringByAppendingPathComponent:@"Default"].UTF8String;

  CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
  gApp = new CompanionApp();
  if (!CefInitialize(args, settings, gApp.get(), nullptr)) {
    gError = [NSString stringWithFormat:@"Chromium did not start (code %d).", CefGetExitCode()];
    return NO;
  }
  gRunning = true;
  gBrowsers = [NSMutableSet set];
  gClient = new Client();
  gViewDelegate = new ViewDelegate();
  gTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *timer) { Pump(); }];
  [NSRunLoop.mainRunLoop addTimer:gTimer forMode:NSRunLoopCommonModes];
  return YES;
#else
  return NO;
#endif
}

@end

// MARK: - One browser

@implementation ChromiumBrowser {
#if COMPANION_CEF
  CefRefPtr<CefBrowserView> _view;
  CefRefPtr<CefWindow> _window;
  CefRefPtr<CefRegistration> _observer;
  NSMutableDictionary<NSNumber *, void (^)(NSString *, NSString *)> *_pending;
  BOOL _visible;
  /// Where the pane wants it, in screen points; it is put back there if
  /// anything else moves or resizes it.
  NSRect _target;
  id _moveObserver;
  id _resizeObserver;
#endif
}

- (instancetype)initWithURL:(NSString *)url delegate:(id<ChromiumBrowserDelegate>)delegate {
#if COMPANION_CEF
  if (!gRunning || !gReady) return nil;
  CefBrowserSettings settings;
  CefRefPtr<CefBrowserView> view = CefBrowserView::CreateBrowserView(gClient, url.UTF8String, settings,
                                                                     nullptr, nullptr, gViewDelegate);
  if (!view) return nil;
  self = [self initWithPopupView:view delegate:delegate];
  _url = [url copy];
  return self;
#else
  return nil;
#endif
}

#if COMPANION_CEF
- (instancetype)initWithPopupView:(CefRefPtr<CefBrowserView>)view delegate:(id<ChromiumBrowserDelegate>)delegate {
  if (!(self = [super init])) return nil;
  _delegate = delegate;
  _url = @"";
  _title = @"";
  _view = view;
  _pending = [NSMutableDictionary dictionary];
  [gBrowsers addObject:self];
  _window = CefWindow::CreateTopLevelWindow(new WindowDelegate(view));
  return self;
}

- (CefRefPtr<CefBrowser>)cefBrowser {
  return _view ? _view->GetBrowser() : nullptr;
}

- (NSWindow *)nativeWindow {
  return _window ? WindowOf(_window->GetWindowHandle()) : nil;
}

- (void)cefTitle:(NSString *)title {
  _title = [title copy];
  [_delegate chromiumBrowser:self didChangeTitle:title];
}

- (void)cefURL:(NSString *)url {
  _url = [url copy];
  [_delegate chromiumBrowser:self didChangeURL:url];
}

- (void)cefLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward {
  _loading = loading;
  [_delegate chromiumBrowser:self didChangeLoading:loading canGoBack:back canGoForward:forward];
}

- (void)dealloc {
  if (_moveObserver) [NSNotificationCenter.defaultCenter removeObserver:_moveObserver];
  if (_resizeObserver) [NSNotificationCenter.defaultCenter removeObserver:_resizeObserver];
}

- (void)cefClosed {
  if (_moveObserver) [NSNotificationCenter.defaultCenter removeObserver:_moveObserver];
  if (_resizeObserver) [NSNotificationCenter.defaultCenter removeObserver:_resizeObserver];
  _moveObserver = nil;
  _resizeObserver = nil;
  for (NSNumber *key in _pending.allKeys) _pending[key](nil, @"The tab closed.");
  [_pending removeAllObjects];
  _observer = nullptr;
  _view = nullptr;
  _window = nullptr;
  [_delegate chromiumBrowserDidClose:self];
  [gBrowsers removeObject:self];
}

- (void)cefEvent:(NSString *)method json:(NSString *)json {
  if (![method isEqualToString:@"Runtime.bindingCalled"]) return;
  NSDictionary *params = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  NSString *name = [params isKindOfClass:[NSDictionary class]] ? params[@"name"] : nil;
  NSString *payload = [params isKindOfClass:[NSDictionary class]] ? params[@"payload"] : nil;
  if (![name isKindOfClass:[NSString class]] || ![payload isKindOfClass:[NSString class]]) return;
  id<ChromiumBrowserDelegate> delegate = _delegate;
  if ([delegate respondsToSelector:@selector(chromiumBrowser:didCallBinding:payload:)]) {
    [delegate chromiumBrowser:self didCallBinding:name payload:payload];
  }
}

/// Sends a DevTools method whose answer is not needed.
- (BOOL)send:(const char *)method params:(CefRefPtr<CefDictionaryValue>)params {
  CefRefPtr<CefBrowser> browser = [self cefBrowser];
  if (!browser) return NO;
  if (!_observer) _observer = browser->GetHost()->AddDevToolsMessageObserver(gClient);
  return browser->GetHost()->ExecuteDevToolsMethod(gNextMessage++, method, params) != 0;
}

- (void)cefResult:(int)messageID ok:(BOOL)ok json:(NSString *)json {
  void (^done)(NSString *, NSString *) = _pending[@(messageID)];
  if (!done) return;
  [_pending removeObjectForKey:@(messageID)];
  ok ? done(json, nil) : done(nil, json.length ? json : @"The page did not run that.");
}
#endif

- (void)showAbove:(NSWindow *)parent frame:(NSRect)screenFrame {
#if COMPANION_CEF
  if (!_window) return;
  if (!_visible) {
    _window->Show();
    _visible = YES;
  }
  NSWindow *window = [self nativeWindow];
  if (!window) return;
  // A part of the pane, not a window of its own: no edge or corner to
  // resize it by, no dragging it away, no shadow, and never key of its own
  // in Mission Control or the window list.
  if (window.styleMask & NSWindowStyleMaskResizable) {
    window.styleMask &= ~NSWindowStyleMaskResizable;
  }
  window.movable = NO;
  window.movableByWindowBackground = NO;
  window.hasShadow = NO;
  window.collectionBehavior |= NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
  if (window.parentWindow != parent) {
    [window.parentWindow removeChildWindow:window];
    [parent addChildWindow:window ordered:NSWindowAbove];
  }
  RoundCorners(window, _cornerRadius);
  NSRect target = NSIntegralRect(screenFrame);
  _target = target;
  if (!_moveObserver) {
    __weak ChromiumBrowser *weakSelf = self;
    __weak NSWindow *weakWindow = window;
    void (^snap)(NSNotification *) = ^(NSNotification *note) {
      ChromiumBrowser *strongSelf = weakSelf;
      NSWindow *strongWindow = weakWindow;
      if (!strongSelf || !strongWindow || !strongSelf->_visible || NSIsEmptyRect(strongSelf->_target)) return;
      if (!NSEqualRects(strongWindow.frame, strongSelf->_target)) {
        [strongWindow setFrame:strongSelf->_target display:YES];
      }
    };
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    _moveObserver = [center addObserverForName:NSWindowDidMoveNotification object:window queue:NSOperationQueue.mainQueue usingBlock:snap];
    _resizeObserver = [center addObserverForName:NSWindowDidResizeNotification object:window queue:NSOperationQueue.mainQueue usingBlock:snap];
  }
  if (NSEqualRects(window.frame, target)) return;
  // Chromium keeps its own idea of where its window is and puts it back
  // there, so it is told (screen points, top-left origin on the primary
  // display), not only moved.
  NSScreen *primary = NSScreen.screens.firstObject;
  CGFloat top = primary ? NSMaxY(primary.frame) - NSMaxY(target) : NSMinY(target);
  _window->SetBounds(CefRect((int)NSMinX(target), (int)top, (int)NSWidth(target), (int)NSHeight(target)));
  // Where Chromium did not take it all the way, AppKit finishes the move.
  if (!NSEqualRects(window.frame, target)) [window setFrame:target display:YES];
#endif
}

- (void)hide {
#if COMPANION_CEF
  if (!_window || !_visible) return;
  NSWindow *window = [self nativeWindow];
  [window.parentWindow removeChildWindow:window];
  _window->Hide();
  _visible = NO;
#endif
}

- (void)load:(NSString *)url {
#if COMPANION_CEF
  CefRefPtr<CefBrowser> browser = [self cefBrowser];
  if (browser) browser->GetMainFrame()->LoadURL(url.UTF8String);
#endif
}

- (void)goBack {
#if COMPANION_CEF
  if (CefRefPtr<CefBrowser> browser = [self cefBrowser]) browser->GoBack();
#endif
}

- (void)goForward {
#if COMPANION_CEF
  if (CefRefPtr<CefBrowser> browser = [self cefBrowser]) browser->GoForward();
#endif
}

- (void)reload {
#if COMPANION_CEF
  if (CefRefPtr<CefBrowser> browser = [self cefBrowser]) browser->Reload();
#endif
}

- (void)stop {
#if COMPANION_CEF
  if (CefRefPtr<CefBrowser> browser = [self cefBrowser]) browser->StopLoad();
#endif
}

- (void)close {
#if COMPANION_CEF
  [self hide];
  if (_window) {
    _window->Close();
  } else if (CefRefPtr<CefBrowser> browser = [self cefBrowser]) {
    browser->GetHost()->CloseBrowser(false);
  }
#endif
}

- (BOOL)ready {
#if COMPANION_CEF
  return [self cefBrowser] != nullptr;
#else
  return NO;
#endif
}

- (void)addScriptOnNewDocument:(NSString *)source {
#if COMPANION_CEF
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("source", source.UTF8String);
  [self send:"Page.addScriptToEvaluateOnNewDocument" params:params];
  CefRefPtr<CefDictionaryValue> now = CefDictionaryValue::Create();
  now->SetString("expression", source.UTF8String);
  [self send:"Runtime.evaluate" params:now];
#endif
}

- (void)addBinding:(NSString *)name {
#if COMPANION_CEF
  // Runtime.enable first: bindingCalled arrives as a Runtime event.
  [self send:"Runtime.enable" params:nullptr];
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("name", name.UTF8String);
  [self send:"Runtime.addBinding" params:params];
#endif
}

- (void)evaluate:(NSString *)expression completion:(void (^)(NSString *_Nullable, NSString *_Nullable))completion {
#if COMPANION_CEF
  CefRefPtr<CefBrowser> browser = [self cefBrowser];
  if (!browser) {
    completion(nil, @"The page is not ready yet.");
    return;
  }
  if (!_observer) _observer = browser->GetHost()->AddDevToolsMessageObserver(gClient);
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", expression.UTF8String);
  params->SetBool("awaitPromise", true);
  params->SetBool("returnByValue", true);
  int messageID = gNextMessage++;
  _pending[@(messageID)] = [completion copy];
  if (browser->GetHost()->ExecuteDevToolsMethod(messageID, "Runtime.evaluate", params) == 0) {
    [_pending removeObjectForKey:@(messageID)];
    completion(nil, @"Chromium did not take the request.");
    return;
  }
  __weak ChromiumBrowser *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    ChromiumBrowser *strongSelf = weakSelf;
    if (!strongSelf) return;
    [strongSelf cefResult:messageID ok:NO json:@"The page did not answer in 30 seconds."];
  });
#else
  completion(nil, @"Chromium is not part of this build.");
#endif
}

@end
