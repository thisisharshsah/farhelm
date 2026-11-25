#include "CrashKit.h"

#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Everything the handler touches is set up before a signal can arrive.
static int note = -1;
static volatile sig_atomic_t written = 0;
static volatile sig_atomic_t silent = 0;

// The signals that end the app because something went wrong in it. SIGTRAP
// is how a failed Swift check arrives (a precondition, a forced unwrap of
// nil). SIGTERM, SIGINT and SIGKILL are someone stopping the app, not a
// crash, and are left alone.
static const int fatal[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS};
static const int fatal_count = sizeof(fatal) / sizeof(fatal[0]);

// A stack for the handler of its own, so a crash from running out of stack
// can still be written down.
static stack_t handler_stack;

static void put(const char *text) {
  // write() is safe in a signal; what it could not write is given up on.
  (void)write(note, text, strlen(text));
}

static void put_number(long value) {
  char digits[24];
  int at = sizeof(digits);
  digits[--at] = '\0';
  unsigned long rest = value < 0 ? (unsigned long)(-value) : (unsigned long)value;
  do {
    digits[--at] = (char)('0' + rest % 10);
    rest /= 10;
  } while (rest > 0 && at > 1);
  if (value < 0) digits[--at] = '-';
  put(digits + at);
}

static void crashkit_handler(int sig, siginfo_t *info, void *context) {
  (void)context;
  // Back to what the system does, first: a second fault, in here or on
  // another thread, ends the app at once.
  signal(sig, SIG_DFL);

  if (!written && !silent && note >= 0) {
    written = 1;
    put("signal ");
    put_number(sig);
    put("\ntime ");
    put_number((long)time(NULL));
    put("\nmain ");
    put_number(pthread_main_np() ? 1 : 0);
    put("\n");

    // Naming the frames looks them up in the loaded libraries, which is
    // not promised to be safe in a signal: in a process broken badly
    // enough it could wait for ever. The lines above are already written,
    // and the alarm ends the app if the lookup has not come back in time.
    signal(SIGALRM, SIG_DFL);
    alarm(3);
    void *frames[128];
    int count = backtrace(frames, 128);
    backtrace_symbols_fd(frames, count, note);
    alarm(0);
  }

  // Returning runs the failing instruction again, now with nothing
  // handling it, so macOS writes its own crash report with the real
  // cause and stack. A signal that was sent (kill, raise, abort) does not
  // come again by itself, so that one is raised: a real fault carries a
  // code above zero that says what kind it was, a sent one does not.
  if (info == NULL || info->si_code <= 0 || info->si_code == SI_USER || info->si_code == SI_QUEUE
      || sig == SIGABRT) {
    raise(sig);
  }
}

static void install(int sig) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_sigaction = crashkit_handler;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&action.sa_mask);
  sigaction(sig, &action, NULL);
}

int crashkit_arm(const char *path) {
  if (note >= 0) {
    crashkit_rearm();
    return 0;
  }
  int opened = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (opened < 0) return -1;
  note = opened;

  if (handler_stack.ss_sp == NULL) {
    handler_stack.ss_size = 64 * 1024;
    handler_stack.ss_sp = malloc(handler_stack.ss_size);
    handler_stack.ss_flags = 0;
    // The other stack is the calling thread's (the main thread's). On any
    // other thread the handler runs on that thread's own stack.
    if (handler_stack.ss_sp != NULL) sigaltstack(&handler_stack, NULL);
  }
  // backtrace() loads what it needs the first time it is called. That is
  // done here, so it is not done inside a signal.
  void *warm[1];
  backtrace(warm, 1);

  for (int index = 0; index < fatal_count; index++) install(fatal[index]);
  return 0;
}

void crashkit_rearm(void) {
  if (note < 0 || written) return;
  for (int index = 0; index < fatal_count; index++) {
    struct sigaction current;
    if (sigaction(fatal[index], NULL, &current) != 0) continue;
    if ((current.sa_flags & SA_SIGINFO) && current.sa_sigaction == crashkit_handler) continue;
    install(fatal[index]);
  }
}

void crashkit_disarm(void) {
  silent = 1;
}
