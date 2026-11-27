// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Implements non-blocking TCP sockets, directory creation, and subprocess spawning for
// driver_openvrlink's data link on Windows and POSIX.

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN 1
#include <winsock2.h>
#include <windows.h>
#include <direct.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <spawn.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
extern char **environ;
#endif

// Omit DriverABI.h here because its standalone Win32 declarations conflict with <windows.h>.
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

intptr_t ovrl_link_connect(uint32_t address, uint16_t port);
int ovrl_link_ready(intptr_t link);
ptrdiff_t ovrl_link_send(intptr_t link, const void *bytes, size_t count);
ptrdiff_t ovrl_link_receive(intptr_t link, void *bytes, size_t capacity);
void ovrl_link_close(intptr_t link);
int ovrl_make_folder(const char *path);
int ovrl_start_program(const char *program, const char *first, const char *second);

#if defined(_WIN32)
typedef SOCKET link_socket;
static int would_block(void) { int error = WSAGetLastError(); return error == WSAEWOULDBLOCK || error == WSAEINPROGRESS; }
#else
typedef int link_socket;
#define INVALID_SOCKET (-1)
#define closesocket close
static int would_block(void) { return errno == EWOULDBLOCK || errno == EAGAIN || errno == EINPROGRESS || errno == EINTR; }
#endif

intptr_t ovrl_link_connect(uint32_t address, uint16_t port) {
#if defined(_WIN32)
    static int started = 0;
    if (!started) {
        WSADATA data;
        if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return -1;
        started = 1;
    }
#endif
    link_socket link = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (link == INVALID_SOCKET) return -1;
#if defined(_WIN32)
    u_long on = 1;
    if (ioctlsocket(link, FIONBIO, &on) != 0) { closesocket(link); return -1; }
#else
    int flags = fcntl(link, F_GETFL, 0);
    if (flags < 0 || fcntl(link, F_SETFL, flags | O_NONBLOCK) != 0) { closesocket(link); return -1; }
#if defined(SO_NOSIGPIPE)
    int quiet = 1;
    setsockopt(link, SOL_SOCKET, SO_NOSIGPIPE, &quiet, sizeof quiet);
#endif
#endif
    struct sockaddr_in to;
    memset(&to, 0, sizeof to);
    to.sin_family = AF_INET;
    to.sin_port = htons(port);
    to.sin_addr.s_addr = htonl(address);
    if (connect(link, (struct sockaddr *)&to, sizeof to) != 0 && !would_block()) { closesocket(link); return -1; }
    return (intptr_t)link;
}

int ovrl_link_ready(intptr_t handle) {
    link_socket link = (link_socket)handle;
    fd_set writable, failed;
    FD_ZERO(&writable);
    FD_ZERO(&failed);
    FD_SET(link, &writable);
    FD_SET(link, &failed);
    struct timeval none = {0, 0};
    int found = select((int)link + 1, NULL, &writable, &failed, &none);
    if (found < 0) return -1;
    if (found == 0) return 0;
    int error = 0;
#if defined(_WIN32)
    int size = sizeof error;
    if (getsockopt(link, SOL_SOCKET, SO_ERROR, (char *)&error, &size) != 0) return -1;
#else
    socklen_t size = sizeof error;
    if (getsockopt(link, SOL_SOCKET, SO_ERROR, &error, &size) != 0) return -1;
#endif
    if (error != 0 || FD_ISSET(link, &failed)) return -1;
    return FD_ISSET(link, &writable) ? 1 : 0;
}

ptrdiff_t ovrl_link_send(intptr_t handle, const void *bytes, size_t count) {
    if (count > 1 << 20) count = 1 << 20;
#if defined(_WIN32)
    int sent = send((link_socket)handle, (const char *)bytes, (int)count, 0);
#elif defined(MSG_NOSIGNAL)
    ptrdiff_t sent = (ptrdiff_t)send((link_socket)handle, bytes, count, MSG_NOSIGNAL);
#else
    ptrdiff_t sent = (ptrdiff_t)send((link_socket)handle, bytes, count, 0);
#endif
    if (sent >= 0) return (ptrdiff_t)sent;
    return would_block() ? 0 : -1;
}

ptrdiff_t ovrl_link_receive(intptr_t handle, void *bytes, size_t capacity) {
    if (capacity > 1 << 20) capacity = 1 << 20;
#if defined(_WIN32)
    int got = recv((link_socket)handle, (char *)bytes, (int)capacity, 0);
#else
    ptrdiff_t got = (ptrdiff_t)recv((link_socket)handle, bytes, capacity, 0);
#endif
    if (got > 0) return (ptrdiff_t)got;
    // recv() returns 0 when the peer closes the connection cleanly.
    if (got == 0) return -1;
    return would_block() ? 0 : -1;
}

void ovrl_link_close(intptr_t handle) { closesocket((link_socket)handle); }

int ovrl_make_folder(const char *path) {
#if defined(_WIN32)
    if (_mkdir(path) == 0) return 0;
    DWORD kind = GetFileAttributesA(path);
    return kind != INVALID_FILE_ATTRIBUTES && (kind & FILE_ATTRIBUTE_DIRECTORY) ? 0 : -1;
#else
    if (mkdir(path, 0755) == 0) return 0;
    struct stat found;
    return stat(path, &found) == 0 && S_ISDIR(found.st_mode) ? 0 : -1;
#endif
}

int ovrl_start_program(const char *program, const char *first, const char *second) {
#if defined(_WIN32)
    // Format `"program" first second`, rejecting `program` paths that contain double quotes.
    char line[1024];
    if (strchr(program, '"') || strlen(program) + strlen(first) + strlen(second) + 8 > sizeof line) return -1;
    snprintf(line, sizeof line, "\"%s\" %s %s", program, first, second);
    STARTUPINFOA start;
    PROCESS_INFORMATION started;
    memset(&start, 0, sizeof start);
    start.cb = sizeof start;
    if (!CreateProcessA(program, line, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &start, &started)) return -1;
    CloseHandle(started.hThread);
    CloseHandle(started.hProcess);
    return 0;
#else
    // Spawn without waiting so we do not block vrserver or alter its SIGCHLD handling. At most one
    // conversion process is spawned per vrserver run, so any unreaped zombie entry is cleaned up on exit.
    char *arguments[] = {(char *)program, (char *)first, (char *)second, NULL};
    pid_t child;
    return posix_spawn(&child, program, NULL, NULL, arguments, environ) == 0 ? 0 : -1;
#endif
}
