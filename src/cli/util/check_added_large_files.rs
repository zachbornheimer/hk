use crate::Result;
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

const DEFAULT_MAX_SIZE_KB: u64 = 500;

#[derive(Debug, usage_rs::Args)]
#[usage(effect = "read")]
pub struct CheckAddedLargeFiles {
    /// Maximum file size in kilobytes
    #[usage(long, default_value_t = DEFAULT_MAX_SIZE_KB, default = "500")]
    pub maxkb: u64,

    /// Base ref of the pushed range: check only the files the range adds,
    /// not the ones it modifies that the remote already carries at size
    #[usage(long)]
    pub from_ref: Option<String>,

    /// End ref of the pushed range [default: HEAD]
    #[usage(long)]
    pub to_ref: Option<String>,

    /// Files to check
    #[usage(arg, required)]
    pub files: Vec<PathBuf>,
}

impl CheckAddedLargeFiles {
    pub async fn run(&self) -> Result<()> {
        let max_size_bytes = self.maxkb * 1024;
        let mut files = self.files.clone();
        if let Some(from_ref) = &self.from_ref {
            let to_ref = self.to_ref.as_deref().unwrap_or("HEAD");
            match added_paths_in_range(from_ref, to_ref) {
                // A file the range only modifies is not introduced by the
                // push: the remote already carries it, at size. Only what
                // the range adds is this guard's business.
                Ok(added) => files.retain(|file| added.contains(file)),
                Err(err) => {
                    warn!("could not diff {from_ref}...{to_ref}: {err}; checking every given file")
                }
            }
        }

        let mut found_large = false;

        for file_path in &files {
            if is_too_large(file_path, max_size_bytes)? {
                println!("{}", file_path.display());
                found_large = true;
            }
        }

        if found_large {
            return Err(eyre::eyre!("Large files found"));
        }

        Ok(())
    }
}

/// The paths the pushed range adds: paths present in `to_ref`'s tree that
/// `from_ref`'s tree lacks. A tree set-difference, not `git diff
/// --diff-filter=A`: a renamed-in file is new at its path (the remote does
/// not carry it there), and a file the range only modifies is old (the
/// remote already has it, at size) — only the first kind is this guard's
/// business. An unresolvable ref is an error the caller turns into a
/// fallback to checking every given file.
fn added_paths_in_range(from_ref: &str, to_ref: &str) -> Result<HashSet<PathBuf>> {
    let old = tree_paths(from_ref)?;
    let new = tree_paths(to_ref)?;
    Ok(new.into_iter().filter(|path| !old.contains(path)).collect())
}

/// Every path in `ref_`'s tree, keeping names that are not valid UTF-8.
fn tree_paths(ref_: &str) -> Result<HashSet<PathBuf>> {
    Ok(crate::git::git_read_raw_paths([
        "ls-tree",
        "-r",
        "--name-only",
        "-z",
        "--end-of-options",
        ref_,
    ])?
    .into_iter()
    .collect())
}

fn is_too_large(path: &PathBuf, max_size: u64) -> Result<bool> {
    let metadata = match fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return Ok(false), // File doesn't exist or can't be accessed
    };

    // Skip directories
    if metadata.is_dir() {
        return Ok(false);
    }

    Ok(metadata.len() > max_size)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::NamedTempFile;

    #[test]
    fn test_small_file() {
        let file = NamedTempFile::new().unwrap();
        fs::write(file.path(), "small content").unwrap();

        let result = is_too_large(&file.path().to_path_buf(), 1024).unwrap();
        assert!(!result);
    }

    #[test]
    fn test_large_file() {
        let file = NamedTempFile::new().unwrap();
        // Create a 2KB file
        let large_content = vec![b'x'; 2048];
        fs::write(file.path(), large_content).unwrap();

        let result = is_too_large(&file.path().to_path_buf(), 1024).unwrap();
        assert!(result);
    }

    #[test]
    fn test_file_exactly_at_limit() {
        let file = NamedTempFile::new().unwrap();
        // Create exactly 1024 bytes
        let content = vec![b'x'; 1024];
        fs::write(file.path(), content).unwrap();

        let result = is_too_large(&file.path().to_path_buf(), 1024).unwrap();
        assert!(!result); // Equal to limit is OK
    }

    #[test]
    fn test_file_one_byte_over_limit() {
        let file = NamedTempFile::new().unwrap();
        // Create 1025 bytes
        let content = vec![b'x'; 1025];
        fs::write(file.path(), content).unwrap();

        let result = is_too_large(&file.path().to_path_buf(), 1024).unwrap();
        assert!(result);
    }

    #[test]
    fn test_empty_file() {
        let file = NamedTempFile::new().unwrap();
        fs::write(file.path(), "").unwrap();

        let result = is_too_large(&file.path().to_path_buf(), 1024).unwrap();
        assert!(!result);
    }

    #[test]
    fn test_nonexistent_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let file = dir.path().join("nonexistent");

        let result = is_too_large(&file, 1024).unwrap();
        assert!(!result);
    }

    #[test]
    fn test_directory() {
        let dir = tempfile::TempDir::new().unwrap();

        let result = is_too_large(&dir.path().to_path_buf(), 1024).unwrap();
        assert!(!result); // Directories should be skipped
    }

    // The cargo test working directory is this crate's checkout, a git
    // repository, so HEAD resolves and its tree is not empty.
    #[test]
    fn test_added_paths_in_range_is_empty_for_identical_refs() {
        assert!(added_paths_in_range("HEAD", "HEAD").unwrap().is_empty());
    }

    #[test]
    fn test_added_paths_in_range_errors_on_unresolvable_ref() {
        // An unresolvable base is an error the caller falls back on, never a
        // silent pass: a range guard that cannot diff must check every file.
        assert!(added_paths_in_range("hk-no-such-ref", "HEAD").is_err());
    }

    #[test]
    fn test_tree_paths_of_head_is_not_empty() {
        assert!(!tree_paths("HEAD").unwrap().is_empty());
    }
}
