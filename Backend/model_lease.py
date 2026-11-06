"""Cross-process local model lease; all models share one per-user GPU budget.

Locking different model paths separately permits two large models to exhaust
the same GPU. Deliberately serialize all local model loads for this user.
The normalized model digest is available for diagnostics, not a lock partition.
"""
import fcntl
import hashlib
import os
from pathlib import Path
import stat
import time


class ModelLease:
    def __init__(self, model_path, timeout=120, progress=None, *, lock_directory=None):
        if not 0 <= timeout <= 120:
            raise ValueError("模型等待时间必须在0至120秒之间")
        self.model_path = str(Path(model_path).expanduser().resolve())
        self.model_digest = hashlib.sha256(os.fsencode(self.model_path)).hexdigest()
        self.timeout = timeout
        self.progress = progress
        self.directory = Path(lock_directory) if lock_directory is not None else (
            # Do not use TMPDIR: an App and a CLI may have different values.
            Path("/tmp").resolve() / f"knowledgespine-model-lease-{os.getuid()}")
        self._fd = None
        self._owner_pid = None

    def _open_lock(self):
        try:
            self.directory.mkdir(mode=0o700)
        except FileExistsError:
            pass
        directory_stat = self.directory.lstat()
        if (not stat.S_ISDIR(directory_stat.st_mode) or directory_stat.st_uid != os.getuid()
                or stat.S_IMODE(directory_stat.st_mode) & 0o077):
            raise PermissionError("模型锁目录不安全；拒绝使用共享或符号链接目录")
        directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            actual = os.fstat(directory_fd)
            if (actual.st_dev, actual.st_ino) != (directory_stat.st_dev, directory_stat.st_ino):
                raise PermissionError("模型锁目录已被替换")
            fd = os.open("all-models.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=directory_fd)
        finally:
            os.close(directory_fd)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            os.close(fd)
            raise PermissionError("模型锁文件权限不安全")
        return fd

    def acquire(self):
        if self._fd is not None:
            if self._owner_pid != os.getpid():
                raise RuntimeError("子进程不能复用父进程的模型锁")
            return self
        fd = self._open_lock()
        deadline, announced = time.monotonic() + self.timeout, False
        try:
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if not announced:
                        announced = True
                        if self.progress:
                            self.progress("正在等待本机模型空闲；另一个任务正在使用本地模型")
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("等待本机模型空闲超时；另一个任务仍在处理，请稍后重试。原稿未改变")
                    time.sleep(min(0.1, remaining))
        except BaseException:
            os.close(fd)
            raise
        self._fd, self._owner_pid = fd, os.getpid()
        return self

    def close(self):
        if self._fd is None:
            return
        fd, owner = self._fd, self._owner_pid
        self._fd, self._owner_pid = None, None
        try:
            # A forked child's duplicate must not explicitly unlock its parent.
            if owner == os.getpid():
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

    def __enter__(self):
        return self.acquire()

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()


def acquire_model_lease(model_path, timeout=120, progress=None):
    return ModelLease(model_path, timeout=timeout, progress=progress).acquire()
