---
layout: tutorial
order: 3
title: "RAII & Container Resource Discipline"
description: "Deterministic cleanup is a vibe on a fat host and a survival skill in a 256MB cgroup."
duration: "10 minutes"
kind: Concepts
---

# RAII & Container Resource Discipline

Most C++ resources you'll meet in a service — heap memory,
file descriptors, sockets, mutexes, log handles, gRPC channels
— are *acquirable*: there's a system call or constructor that
hands you a handle and an obligation to give it back. **RAII —
Resource Acquisition Is Initialization** — is the C++ idiom
that ties that obligation to the *lifetime* of an object on the
stack instead of to a remembered call to `cleanup()` somewhere
in the function. Constructor acquires; destructor releases;
the language runs both for you on every exit path, including
the exit paths you forgot existed.

{% include excalidraw.html name="03-raii-discipline" caption="RAII vs manual cleanup: destructors fire on every exit path." %}

On a development workstation with 64 cores, 64 GB of RAM, and
nothing else competing, leaking a few hundred file descriptors
or a hundred MB of memory is cosmetic. The kernel reclaims it
all when the process exits, and the process exits often during
development. **Inside a container, the math changes
qualitatively.** The kernel still cleans up at process exit,
but in the meantime you're operating against `nofile=1024` (or
less), `pids.max=200`, `memory.high=256M`, and a long-running
service that's expected to stay up for weeks. Small leaks
compound. A 200-byte allocation lost on every request becomes
17 MB after a million requests; over a week of typical traffic
that's the difference between staying inside `memory.high` and
getting throttled into a cgroup-OOM-kill at 03:14 on a Sunday.
On the file-descriptor side, leaking one fd per request hits
`EMFILE` ("Too many open files") in ~17 minutes at 1 req/sec
on a `nofile=1024` cgroup, and the service starts returning
500s with no other warning sign.

RAII is the cheapest insurance you can buy against this
failure mode. It costs you typing a class name once. It pays
out every time an exception fires, every time you write a new
early `return` for an error case, every time someone refactors
the function and accidentally adds a third early-exit. The
{% include section.html n=12 %} debugging chapter spends a lot
of time on tools that find leaks; this section is about making
the leaks impossible to write in the first place.

## What RAII actually is

The mechanic is two language features working together:

1. **Object lifetime is bound to scope.** When you write
   `Connection conn{...};` in a function, the `Connection`
   object's storage is on the stack frame. When the function
   returns — by any path — the destructor `~Connection()`
   runs.
2. **Destructors run during stack unwinding.** When an
   exception propagates out of a function, the stack unwinds
   and every destructor for every object whose constructor
   completed runs in reverse order of construction. This is
   not "best effort"; it is a guarantee of the language,
   barring undefined behavior or `std::terminate`.

Together those two give you a deal: **you write the cleanup
once, in the destructor, and the language calls it on every
exit path**. You don't have to remember to put `close(fd)` in
each `if` branch. You don't have to remember to release the
lock when the function throws. You don't have to write
`try`/`catch` at every layer. The destructor runs.

## Three failure modes that disappear with RAII

To make this concrete, here's a function that opens a file,
reads a counter from it, and returns the count. Three different
ways it can leak the file descriptor:

```cpp
// LEAKS. Don't ship this.
int read_count(const char* path) {
    int fd = ::open(path, O_RDONLY);
    if (fd < 0) {
        return -1;                     // (1) leaks nothing — fd was never acquired. OK.
    }
    char buf[64];
    ssize_t n = ::read(fd, buf, sizeof(buf));
    if (n < 0) {
        return -1;                     // (2) early return — fd never closed. LEAKS.
    }
    int v = parse_int(buf, n);         // (3) if parse_int throws, fd never closed. LEAKS.
    ::close(fd);
    return v;
}
```

The three failure modes:

1. **Early return forgets cleanup** (case 2). Easy to write,
   easy to merge in code review, ships to prod, leaks one fd
   per failed read. Multiply by call rate and runtime, and
   you have a clock counting down to `EMFILE`.
2. **Exception unwinds past the cleanup** (case 3). If
   `parse_int` is a templated helper that grew a `throw`
   somewhere, every `read_count` caller now leaks. The git
   blame won't point at this function.
3. **Refactoring adds a fourth exit path** that nobody
   updated to call `close()`. This one is the most common
   in practice — a function with three exit paths is fine
   today and broken six months from now.

The RAII version handles all three by tying the fd's lifetime
to a stack object:

```cpp
// A minimal RAII wrapper. unique_fd is a movable, non-copyable
// owner of a single open file descriptor. Destructor closes it
// if it's still open. About as small as a real type gets.
class unique_fd {
    int fd_ = -1;
public:
    unique_fd() = default;
    explicit unique_fd(int fd) noexcept : fd_(fd) {}
    ~unique_fd() noexcept { if (fd_ >= 0) ::close(fd_); }

    unique_fd(unique_fd&& o) noexcept : fd_(o.fd_) { o.fd_ = -1; }
    unique_fd& operator=(unique_fd&& o) noexcept {
        if (this != &o) {
            if (fd_ >= 0) ::close(fd_);
            fd_ = o.fd_;
            o.fd_ = -1;
        }
        return *this;
    }
    unique_fd(const unique_fd&)            = delete;
    unique_fd& operator=(const unique_fd&) = delete;

    int  get()     const noexcept { return fd_; }
    bool is_open() const noexcept { return fd_ >= 0; }
    int  release() noexcept { int t = fd_; fd_ = -1; return t; }
};

int read_count(const char* path) {
    unique_fd fd{ ::open(path, O_RDONLY) };
    if (!fd.is_open()) return -1;       // destructor doesn't close (-1).
    char buf[64];
    ssize_t n = ::read(fd.get(), buf, sizeof(buf));
    if (n < 0)        return -1;        // destructor closes fd. ✓
    return parse_int(buf, n);           // throws? destructor still closes fd. ✓
}                                       // normal exit? destructor closes fd. ✓
```

Twenty extra lines once, every caller benefits forever. Notice
what's *not* in the second version: there is no `close(fd)`
call in `read_count` at all. The cleanup lives in the type, not
the function. The function just describes intent.

## The four resource classes you'll meet

In practice every C++ container service hits four shapes of
resource. Each has a standard or near-standard RAII type:

| resource | RAII type | what destructor does |
|---|---|---|
| heap memory | `std::unique_ptr`, `std::shared_ptr`, `std::vector`, `std::string` | calls `delete` / `free` / `deallocate` |
| file descriptors | custom `unique_fd` (no std type yet); `std::fstream` for files specifically | `::close(fd)` |
| mutexes | `std::lock_guard`, `std::unique_lock`, `std::scoped_lock` | `unlock()` |
| OS handles (sockets, epoll, eventfd, signalfd, timerfd) | custom wrappers, often built on `unique_fd` | `::close(fd)` |

There's a noticeable gap in the standard library here: `fd_t`
isn't standardized yet. P1885 / P2146 have proposed
`std::unique_fd` for years, no consensus on the design. Every
serious C++ codebase ends up writing its own. {% include
section.html n=7 %} uses a `unique_fd` for `io_uring` setup;
{% include section.html n=9 %} uses one for sockets. The same
twenty-line type works for both. It's the smallest infinitely-
reusable C++ class you'll write.

For mutexes the standard does the right thing already.
**Never** call `mutex.lock()` and `mutex.unlock()` directly in
modern code; the existence of `std::lock_guard{m}` makes the
manual version both wordier and a bug:

```cpp
// Don't.
mtx.lock();
do_work();
if (early_out) return;        // ← deadlock waiting to be discovered
mtx.unlock();

// Do.
{
    std::lock_guard g{mtx};
    do_work();
    if (early_out) return;    // unlock happens. always.
}
```

## What this section does NOT promise

A few honest caveats so you don't oversell RAII to teammates:

- **RAII does not save you from circular ownership.** A
  `shared_ptr<A>` holding a `shared_ptr<B>` that holds a
  `shared_ptr<A>` leaks both. Use `weak_ptr` or
  redesign. {% include section.html n=12 %} covers
  diagnosis with sanitizers.
- **RAII does not save you from `std::terminate`.** A
  destructor that throws is a contract violation; the
  runtime calls `std::terminate` and skips remaining
  destructors. Mark destructors `noexcept` (the default)
  and don't throw from them.
- **RAII does not save you from the OS killing your
  process.** If the cgroup OOM-killer fires, your
  destructors don't run. RAII reduces the *probability*
  of cgroup-OOM by keeping the working set tight; it
  isn't a guarantee that the kernel won't shoot you.
- **RAII does not solve memory-bandwidth or cache
  problems.** Those are layout problems, covered in
  {% include section.html n=7 %}. RAII tells you *when*
  cleanup happens; layout determines *what data lives where*.

## Where this connects forward

RAII shows up in every later section as a baseline assumption:

- {% include section.html n=7 %} (Memory) treats `unique_ptr`
  and PMR allocators as the default; raw `new`/`delete` are
  diagnostic tools, not API.
- {% include section.html n=8 %} (I/O Latency) wraps the
  `io_uring` and socket fds in `unique_fd`. The `io_uring`
  setup-and-teardown sequence is six syscalls; doing them
  manually is a bug factory.
- {% include section.html n=9 %} (Networking) uses RAII for
  `epoll_create1` fds and signalfd handles, which is also why
  shutdown is clean rather than racy.
- {% include section.html n=12 %} (Debugging) covers what
  AddressSanitizer, LeakSanitizer, and Valgrind tell you when
  RAII is *missing* — the resource still ends up in their
  reports.

The pattern itself is simple. The discipline is using it
*everywhere*, even for resources that "feel small enough not to
matter." In a container, no resource is small enough not to
matter.

## Lab tip — see the failure on your machine

If you want to feel the difference rather than read about it,
the smallest reproducer is a tight loop that opens files
without closing them, run inside a container with
`--ulimit nofile=64`. The leaky version dies in roughly 60
iterations with `errno=24, EMFILE`. The RAII version runs
forever. Total cost: about 30 lines of C++ and a one-line
`podman run`. A worked-out version of this becomes part of
{% include section.html n=8 %}'s demo material; the inline
example above is enough to internalize the concept first.
