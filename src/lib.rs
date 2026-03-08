#![allow(clippy::too_many_arguments)]

use pgrx::guc::{GucContext, GucFlags, GucRegistry, GucSetting};
use pgrx::is_a;
use pgrx::pg_sys;
use pgrx::prelude::*;
use std::ffi::CString;

pg_module_magic!();

static BLOCK_COPY_ENABLED: GucSetting<bool> = GucSetting::<bool>::new(true);
// Comma-separated list of roles that are always blocked, including superusers.
static BLOCKED_ROLES: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
// Direction-specific blocking (apply only when enabled=on and user is not a superuser).
static BLOCK_TO: GucSetting<bool> = GucSetting::<bool>::new(true);
static BLOCK_FROM: GucSetting<bool> = GucSetting::<bool>::new(true);
// Block COPY TO/FROM PROGRAM for all users, including superusers.
static BLOCK_PROGRAM: GucSetting<bool> = GucSetting::<bool>::new(true);

static mut PREV_PROCESS_UTILITY_HOOK: pg_sys::ProcessUtility_hook_type = None;

struct ProcessUtilityArgs {
    pstmt: *mut pg_sys::PlannedStmt,
    query_string: *const std::os::raw::c_char,
    read_only_tree: bool,
    context: pg_sys::ProcessUtilityContext::Type,
    params: pg_sys::ParamListInfo,
    query_env: *mut pg_sys::QueryEnvironment,
    dest: *mut pg_sys::DestReceiver,
    qc: *mut pg_sys::QueryCompletion,
}

unsafe fn block_copy_process_utility(args: ProcessUtilityArgs) {
    let node = (*args.pstmt).utilityStmt;
    if !node.is_null() && is_a(node, pg_sys::NodeTag::T_CopyStmt) {
        let copy_stmt = node as *mut pg_sys::CopyStmt;
        let is_from = (*copy_stmt).is_from;
        let is_program = (*copy_stmt).is_program;

        let username = get_current_username().unwrap_or_else(|| "unknown".to_string());
        let in_blocked_list = BLOCKED_ROLES
            .get()
            .and_then(|cstr| cstr.to_str().ok().map(|s| s.to_owned()))
            .map(|list| list.split(',').map(str::trim).any(|r| r == username))
            .unwrap_or(false);

        // COPY TO/FROM PROGRAM is blocked for everyone (including superusers) when block_program=on.
        let program_blocked = is_program && BLOCK_PROGRAM.get();

        // Direction-based blocking applies to non-superusers when enabled=on.
        let direction_blocked = if is_from {
            BLOCK_FROM.get()
        } else {
            BLOCK_TO.get()
        };
        let should_block = in_blocked_list
            || program_blocked
            || (BLOCK_COPY_ENABLED.get() && !pg_sys::superuser() && direction_blocked);

        if should_block {
            pgrx::log!("current_user = {:?}", username);
            let direction = if is_from { "FROM" } else { "TO" };
            let suffix = if is_program { " PROGRAM" } else { "" };
            pgrx::error!("COPY {}{} command is not allowed", direction, suffix);
        }
    }

    match PREV_PROCESS_UTILITY_HOOK {
        Some(prev) => prev(
            args.pstmt,
            args.query_string,
            args.read_only_tree,
            args.context,
            args.params,
            args.query_env,
            args.dest,
            args.qc,
        ),
        None => pg_sys::standard_ProcessUtility(
            args.pstmt,
            args.query_string,
            args.read_only_tree,
            args.context,
            args.params,
            args.query_env,
            args.dest,
            args.qc,
        ),
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn hook_trampoline(
    pstmt: *mut pg_sys::PlannedStmt,
    query_string: *const std::os::raw::c_char,
    read_only_tree: bool,
    context: pg_sys::ProcessUtilityContext::Type,
    params: pg_sys::ParamListInfo,
    query_env: *mut pg_sys::QueryEnvironment,
    dest: *mut pg_sys::DestReceiver,
    qc: *mut pg_sys::QueryCompletion,
) {
    unsafe {
        block_copy_process_utility(ProcessUtilityArgs {
            pstmt,
            query_string,
            read_only_tree,
            context,
            params,
            query_env,
            dest,
            qc,
        });
    }
}

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    GucRegistry::define_bool_guc(
        c"block_copy_command.enabled",
        c"Block COPY commands for non-superusers",
        c"When on (default), all COPY commands from non-superusers are blocked. Superusers are always allowed unless listed in block_copy_command.blocked_roles.",
        &BLOCK_COPY_ENABLED,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"block_copy_command.blocked_roles",
        c"Comma-separated list of roles always blocked from COPY",
        c"Roles in this list are blocked from running COPY regardless of superuser status or the enabled setting.",
        &BLOCKED_ROLES,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_bool_guc(
        c"block_copy_command.block_to",
        c"Block COPY TO commands for non-superusers",
        c"When on (default), COPY TO (export) is blocked for non-superusers. Set to off to allow COPY TO while keeping COPY FROM blocked.",
        &BLOCK_TO,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_bool_guc(
        c"block_copy_command.block_from",
        c"Block COPY FROM commands for non-superusers",
        c"When on (default), COPY FROM (import) is blocked for non-superusers. Set to off to allow COPY FROM while keeping COPY TO blocked.",
        &BLOCK_FROM,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_bool_guc(
        c"block_copy_command.block_program",
        c"Block COPY TO/FROM PROGRAM for all users including superusers",
        c"When on (default), COPY TO/FROM PROGRAM is blocked for all users including superusers. This prevents shell command execution via COPY.",
        &BLOCK_PROGRAM,
        GucContext::Suset,
        GucFlags::default(),
    );

    unsafe {
        PREV_PROCESS_UTILITY_HOOK = pg_sys::ProcessUtility_hook;
        pg_sys::ProcessUtility_hook = Some(hook_trampoline);
    }
}

fn get_current_username() -> Option<String> {
    unsafe {
        let user_oid = pg_sys::GetUserId();
        // noerr = true: returns NULL instead of raising an error if OID is not found
        let name_ptr = pg_sys::GetUserNameFromId(user_oid, true);
        if name_ptr.is_null() {
            None
        } else {
            Some(
                std::ffi::CStr::from_ptr(name_ptr)
                    .to_string_lossy()
                    .into_owned(),
            )
        }
    }
}

extension_sql_file!(".././sql/hooks.sql");

/// Required by pgrx to configure the test PostgreSQL instance.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec!["shared_preload_libraries = 'block_copy_command'"]
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    // helpers
    fn show(guc: &str) -> String {
        Spi::get_one::<String>(&format!("SHOW {guc}"))
            .unwrap()
            .unwrap_or_default()
    }

    // DDL / DML / SELECT pass-through

    #[pg_test]
    fn test_create_and_drop_table_allowed() {
        Spi::run("CREATE TEMP TABLE _test_bcc (id int)").unwrap();
        Spi::run("DROP TABLE _test_bcc").unwrap();
    }

    #[pg_test]
    fn test_select_allowed() {
        let val = Spi::get_one::<i32>("SELECT 42").unwrap();
        assert_eq!(val, Some(42));
    }

    #[pg_test]
    fn test_insert_update_delete_allowed() {
        Spi::run("CREATE TEMP TABLE _test_dml (id int, v text)").unwrap();
        Spi::run("INSERT INTO _test_dml VALUES (1, 'a'), (2, 'b')").unwrap();
        Spi::run("UPDATE _test_dml SET v = 'x' WHERE id = 1").unwrap();
        Spi::run("DELETE FROM _test_dml WHERE id = 2").unwrap();
        let count = Spi::get_one::<i64>("SELECT count(*) FROM _test_dml")
            .unwrap()
            .unwrap();
        assert_eq!(count, 1);
        Spi::run("DROP TABLE _test_dml").unwrap();
    }

    // GUC defaults
    #[pg_test]
    fn test_guc_enabled_default_on() {
        assert_eq!(show("block_copy_command.enabled"), "on");
    }

    #[pg_test]
    fn test_guc_block_to_default_on() {
        assert_eq!(show("block_copy_command.block_to"), "on");
    }

    #[pg_test]
    fn test_guc_block_from_default_on() {
        assert_eq!(show("block_copy_command.block_from"), "on");
    }

    #[pg_test]
    fn test_guc_block_program_default_on() {
        assert_eq!(show("block_copy_command.block_program"), "on");
    }

    #[pg_test]
    fn test_guc_blocked_roles_default_empty() {
        assert_eq!(show("block_copy_command.blocked_roles"), "");
    }

    //  GUC round-trips (SET → SHOW → restore)
    // These run as the pgrx test superuser, so Suset GUCs are writable.

    #[pg_test]
    fn test_guc_block_to_roundtrip() {
        Spi::run("SET block_copy_command.block_to = off").unwrap();
        assert_eq!(show("block_copy_command.block_to"), "off");
        Spi::run("SET block_copy_command.block_to = on").unwrap();
        assert_eq!(show("block_copy_command.block_to"), "on");
    }

    #[pg_test]
    fn test_guc_block_from_roundtrip() {
        Spi::run("SET block_copy_command.block_from = off").unwrap();
        assert_eq!(show("block_copy_command.block_from"), "off");
        Spi::run("SET block_copy_command.block_from = on").unwrap();
        assert_eq!(show("block_copy_command.block_from"), "on");
    }

    #[pg_test]
    fn test_guc_block_program_roundtrip() {
        Spi::run("SET block_copy_command.block_program = off").unwrap();
        assert_eq!(show("block_copy_command.block_program"), "off");
        Spi::run("SET block_copy_command.block_program = on").unwrap();
        assert_eq!(show("block_copy_command.block_program"), "on");
    }

    #[pg_test]
    fn test_guc_blocked_roles_roundtrip() {
        Spi::run("SET block_copy_command.blocked_roles = 'alice, bob'").unwrap();
        assert_eq!(show("block_copy_command.blocked_roles"), "alice, bob");
        Spi::run("RESET block_copy_command.blocked_roles").unwrap();
        assert_eq!(show("block_copy_command.blocked_roles"), "");
    }

    // GUC independence: changing one direction does not affect the other

    #[pg_test]
    fn test_block_to_and_block_from_are_independent() {
        Spi::run("SET block_copy_command.block_to = off").unwrap();
        assert_eq!(show("block_copy_command.block_from"), "on");
        Spi::run("SET block_copy_command.block_to = on").unwrap();

        Spi::run("SET block_copy_command.block_from = off").unwrap();
        assert_eq!(show("block_copy_command.block_to"), "on");
        Spi::run("SET block_copy_command.block_from = on").unwrap();
    }

    // COPY blocking itself is tested via pg_regress (tests/pg_regress/sql/copy_blocked.sql)
    // because SPI explicitly rejects COPY before ProcessUtility is ever called,
    // making it untestable through Spi::run.
}
