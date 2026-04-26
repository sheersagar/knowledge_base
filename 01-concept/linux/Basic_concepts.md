# Linux and System Administration

## 1. Process Management

### 1.1 Zombie Process
A process that has completed execution but still has an entry in the Process Table. (It's a corpse waiting for a death certificate)

**Why it happen**

When a child process finishes, it sends a ```SIGCHLD``` signal to its parent. The parent is then supposed to execute a ```wait()``` system call to collect the child's exit status.

- __The Glitch :__ If the parent process is poorly programmed or busy and fails to "reap" the child, the child stays in the process table as a zombie.

**Impact**
- __RAM/CPU :__ ```Negligible```, Since the process isn't running, it consumes no CPU and has released its memory.
- __The Real Danger :__ Every zombie occupies a __PID (Process ID)__. Operating systems have a finite number of PIDs. If zombies multiply uncontrollably, no new process will start since system has "ran out" of IDs.

---

**How to Identify**

```bash
ps -ef | grep defunct
```

---

### 1.2 Orphan Processes
An __Oprphan process__ is a process that is still running, but its parent process has died or terminated before it did.

**Why it happen**

It occurs when a parent process exits (either intentionally or due to a crash) while its children are still executing.

**Impact**
- __System Health :__ ```Usually Minimal```, In Linux/macOS, the system handles this automatically. The ```init``` process (PID 1) "adopts" the orphan.
- __Resources :__ Since these are active processes, they continue to consume RAM and CPU just like any other running tasks.
---

**How to Identify**

```bash
ps -ef | awk '$3 == 1'
```