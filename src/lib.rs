use pgrx::pg_sys;
use pgrx::prelude::*;

pg_module_magic!();

static mut PREV_PROCESS_UTILITY_HOOK: pg_sys::ProcessUtility_hook_type = None;

#[pg_guard]
unsafe extern "C-unwind" fn block_copy_process_utility(
    pstmt: *mut pg_sys::PlannedStmt,
    query_string: *const std::os::raw::c_char,
    read_only_tree: bool,
    context: pg_sys::ProcessUtilityContext,
    params: *mut pg_sys::ParamListInfoData,
    query_env: *mut pg_sys::QueryEnvironment,
    dest: *mut pg_sys::DestReceiver,
    qc: *mut pg_sys::QueryCompletion,
) {
    unsafe {
        let node = (*pstmt).utilityStmt;
        if !node.is_null() && pg_sys::is_a(node, pg_sys::NodeTag::T_CopyStmt) {
            pgrx::error!("COPY command is not allowed");
        }

        match PREV_PROCESS_UTILITY_HOOK {
            Some(prev) => prev(
                pstmt,
                query_string,
                read_only_tree,
                context,
                params,
                query_env,
                dest,
                qc,
            ),
            None => pg_sys::standard_ProcessUtility(
                pstmt,
                query_string,
                read_only_tree,
                context,
                params,
                query_env,
                dest,
                qc,
            ),
        }
    }
}

#[pg_guard]
#[no_mangle]
pub extern "C-unwind" fn _PG_init() {
    unsafe {
        PREV_PROCESS_UTILITY_HOOK = pg_sys::ProcessUtility_hook;
        pg_sys::ProcessUtility_hook = Some(block_copy_process_utility);
    }
}

extension_sql_file!("./sql/hooks.sql");

#[cfg(test)]
mod tests {}
