//! 系统 libleveldb 的 C API 绑定（dlopen，不需要 leveldb-devel）。
//!
//! 为什么全程不调 leveldb_close：Fedora 的 leveldb 1.23 在 `~VersionSet` 里
//! 有个断言 bug，干净打开的库一 close 也必崩（实测 SIGABRT）。句柄干脆不关，
//! 随进程退出释放。代价是打开期间本进程持有 LOCK，rime 想同时开这个库会失败
//! （GUI 里对用户有提示）。
//!
//! 读之前先用 `is_locked()` 探 LOCK（fcntl POSIX 锁，和 leveldb 的加锁方式
//! 一致），锁着就拷一份快照来读，避免去碰 leveldb 打开失败路径。

use libloading::Library;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;

type COptions = c_void;
type CDb = c_void;
type CIter = c_void;
type CReadOpts = c_void;
type CWriteOpts = c_void;
type CBatch = c_void;

macro_rules! sym {
    ($lib:expr, $name:literal : ($($arg:ty),*) -> $ret:ty) => {{
        let f: libloading::Symbol<unsafe extern "C" fn($($arg),*) -> $ret> =
            $lib.get(concat!($name, "\0").as_bytes())
                .map_err(|e| format!("缺少符号 {}: {e}", $name))?;
        *f
    }};
}

pub struct LevelDb {
    lib: Library,
    db: *mut CDb,
}

impl LevelDb {
    pub fn open(path: &Path) -> Result<Self, String> {
        Self::open_with(path, false)
    }

    /// `create` = 库不存在时建新库（测试用；管理工具不会凭空建库）。
    pub fn open_with(path: &Path, create: bool) -> Result<Self, String> {
        let lib = unsafe { Library::new("libleveldb.so.1") }
            .or_else(|_| unsafe { Library::new("libleveldb.so") })
            .map_err(|e| format!("加载 libleveldb 失败：{e}"))?;
        let cpath = CString::new(path.as_os_str().as_encoded_bytes())
            .map_err(|_| "路径含 NUL".to_string())?;
        unsafe {
            let opts_create = sym!(lib, "leveldb_options_create": () -> *mut COptions);
            let opts_set = sym!(lib, "leveldb_options_set_create_if_missing": (*mut COptions, u8) -> ());
            let open = sym!(lib, "leveldb_open": (*const COptions, *const c_char, *mut *mut c_char) -> *mut CDb);
            let opts = opts_create();
            opts_set(opts, create as u8);
            let mut err: *mut c_char = ptr::null_mut();
            let db = open(opts, cpath.as_ptr(), &mut err);
            if db.is_null() {
                return Err(take_err(&lib, err).unwrap_or_else(|| "leveldb_open 失败".into()));
            }
            Ok(Self { lib, db })
        }
    }

    /// 全量扫描：按 key 序返回 (key, value)。
    pub fn scan(&self) -> Result<Vec<(String, String)>, String> {
        unsafe {
            let ro_create = sym!(self.lib, "leveldb_readoptions_create": () -> *mut CReadOpts);
            let it_create = sym!(self.lib, "leveldb_create_iterator": (*const CDb, *const CReadOpts) -> *mut CIter);
            let seek = sym!(self.lib, "leveldb_iter_seek_to_first": (*mut CIter) -> ());
            let valid = sym!(self.lib, "leveldb_iter_valid": (*const CIter) -> u8);
            let next = sym!(self.lib, "leveldb_iter_next": (*mut CIter) -> ());
            let get_key = sym!(self.lib, "leveldb_iter_key": (*const CIter, *mut usize) -> *const c_char);
            let get_val = sym!(self.lib, "leveldb_iter_value": (*const CIter, *mut usize) -> *const c_char);
            let it_destroy = sym!(self.lib, "leveldb_iter_destroy": (*mut CIter) -> ());
            let it = it_create(self.db, ro_create());
            let mut out = Vec::new();
            seek(it);
            while valid(it) != 0 {
                let (mut kl, mut vl) = (0usize, 0usize);
                let kp = get_key(it, &mut kl);
                let vp = get_val(it, &mut vl);
                let k = std::slice::from_raw_parts(kp as *const u8, kl).to_vec();
                let v = std::slice::from_raw_parts(vp as *const u8, vl).to_vec();
                out.push((
                    String::from_utf8_lossy(&k).into_owned(),
                    String::from_utf8_lossy(&v).into_owned(),
                ));
                next(it);
            }
            it_destroy(it);
            Ok(out)
        }
    }

    /// 一个 write batch 里完成增删。
    pub fn apply(&self, puts: &[(String, String)], dels: &[String]) -> Result<(), String> {
        unsafe {
            let wo_create = sym!(self.lib, "leveldb_writeoptions_create": () -> *mut CWriteOpts);
            let b_create = sym!(self.lib, "leveldb_writebatch_create": () -> *mut CBatch);
            let b_put = sym!(self.lib, "leveldb_writebatch_put": (*mut CBatch, *const c_char, usize, *const c_char, usize) -> ());
            let b_del = sym!(self.lib, "leveldb_writebatch_delete": (*mut CBatch, *const c_char, usize) -> ());
            let write = sym!(self.lib, "leveldb_write": (*mut CDb, *const CWriteOpts, *mut CBatch, *mut *mut c_char) -> ());
            let b_destroy = sym!(self.lib, "leveldb_writebatch_destroy": (*mut CBatch) -> ());
            let batch = b_create();
            for (k, v) in puts {
                b_put(
                    batch,
                    k.as_ptr() as *const c_char,
                    k.len(),
                    v.as_ptr() as *const c_char,
                    v.len(),
                );
            }
            for k in dels {
                b_del(batch, k.as_ptr() as *const c_char, k.len());
            }
            let mut err: *mut c_char = ptr::null_mut();
            write(self.db, wo_create(), batch, &mut err);
            b_destroy(batch);
            match take_err(&self.lib, err) {
                Some(msg) => Err(msg),
                None => Ok(()),
            }
        }
    }
}

fn take_err(lib: &Library, err: *mut c_char) -> Option<String> {
    if err.is_null() {
        return None;
    }
    unsafe {
        let s = CStr::from_ptr(err).to_string_lossy().into_owned();
        if let Ok(free) = lib.get::<unsafe extern "C" fn(*mut c_void)>(b"leveldb_free\0") {
            free(err as *mut c_void);
        }
        Some(s)
    }
}

/// 探测 leveldb 的 LOCK 是否被别的进程持有（和 leveldb 一样用 fcntl 写锁）。
pub fn is_locked(path: &Path) -> bool {
    let lock = path.join("LOCK");
    let Ok(c) = CString::new(lock.as_os_str().as_encoded_bytes()) else {
        return false;
    };
    unsafe {
        let fd = libc::open(c.as_ptr(), libc::O_RDWR);
        if fd < 0 {
            return false;
        }
        let mut fl: libc::flock = std::mem::zeroed();
        fl.l_type = libc::F_WRLCK as libc::c_short;
        fl.l_whence = libc::SEEK_SET as libc::c_short;
        let r = libc::fcntl(fd, libc::F_SETLK, &fl);
        libc::close(fd);
        r != 0
    }
}

/// 锁着就开快照，否则直连。返回 (句柄, 是否快照)。
pub fn open_any(path: &Path) -> Result<(LevelDb, bool), String> {
    let snapshot = is_locked(path);
    let dir = if snapshot {
        snapshot_copy(path)?
    } else {
        path.to_path_buf()
    };
    Ok((LevelDb::open(&dir)?, snapshot))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_read_roundtrip() {
        let dir = std::env::temp_dir().join(format!("flow-orderdb-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let db = LevelDb::open_with(&dir, true).unwrap();
        assert!(db.scan().unwrap().is_empty());
        db.apply(
            &[
                ("ord/rt|".into(), "然\t冉".into()),
                ("sbb/a".into(), "啊".into()),
            ],
            &[],
        )
        .unwrap();
        let rows = db.scan().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0], ("ord/rt|".into(), "然\t冉".into()));
        db.apply(&[], &["sbb/a".into()]).unwrap();
        assert_eq!(db.scan().unwrap(), vec![("ord/rt|".into(), "然\t冉".into())]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fresh_db_has_lock_file() {
        let dir = std::env::temp_dir().join(format!("flow-orderdb-lock-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let _db = LevelDb::open_with(&dir, true).unwrap();
        assert!(dir.join("LOCK").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// 把整个库目录拷到临时目录（rime 在跑时的只读快照）。
pub fn snapshot_copy(src: &Path) -> Result<PathBuf, String> {
    let dst = std::env::temp_dir().join(format!("flow-orderdb-snapshot-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dst);
    std::fs::create_dir_all(&dst).map_err(|e| format!("建快照目录失败：{e}"))?;
    for ent in std::fs::read_dir(src).map_err(|e| format!("读库目录失败：{e}"))? {
        let ent = ent.map_err(|e| e.to_string())?;
        if ent.file_type().map_err(|e| e.to_string())?.is_file() {
            std::fs::copy(ent.path(), dst.join(ent.file_name()))
                .map_err(|e| format!("拷贝 {:?} 失败：{e}", ent.file_name()))?;
        }
    }
    Ok(dst)
}
