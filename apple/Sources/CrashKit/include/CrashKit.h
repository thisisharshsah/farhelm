#ifndef CRASHKIT_H
#define CRASHKIT_H

// The part of Companion's crash recording that runs inside a fatal signal.
// It is C because of what a signal handler may do: no memory may be
// allocated and no lock taken, which rules out Swift and Objective-C there.
// The handler writes a few lines to a file opened beforehand; the app makes
// a record of them the next time it starts (CrashRecorder.swift).

/// Opens `path` for the handler's note, emptied, and installs the handler
/// for the fatal signals. Returns 0, or -1 when the file could not be opened
/// (nothing is installed then).
int crashkit_arm(const char *path);

/// Installs the handler again for any signal that something else has since
/// taken over: Chromium sets signal handlers of its own when it starts.
/// Does nothing before crashkit_arm.
void crashkit_rearm(void);

/// The handler writes nothing from here on. Called once a crash has been
/// recorded another way (an uncaught exception ends in an abort, which
/// would otherwise be recorded a second time).
void crashkit_disarm(void);

#endif
