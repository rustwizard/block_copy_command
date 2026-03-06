#![allow(clippy::too_many_arguments)]

use pgrx::is_a;
use pgrx::pg_sys;
use pgrx::prelude::*;

pg_module_magic!();

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
        pgrx::error!("COPY command is not allowed");
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
    unsafe {
        PREV_PROCESS_UTILITY_HOOK = pg_sys::ProcessUtility_hook;
        pg_sys::ProcessUtility_hook = Some(hook_trampoline);
    }
}

extension_sql_file!(".././sql/hooks.sql");

#[cfg(feature = "pg_test")]
extension_sql!(
    "CREATE SCHEMA IF NOT EXISTS tests;",
    name = "create_tests_schema",
);

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

    // COPY blocking is tested via pg_regress (tests/pg_regress/sql/copy_blocked.sql)
    // because SPI explicitly rejects COPY before ProcessUtility is ever called,
    // making it untestable through Spi::run.
}
