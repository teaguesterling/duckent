# How a duckent verb executes its compiled statement list

**Four candidates measured. Two are atomic: A′ and C. Two are not viable: A and B.**

| | atomic? | keeps `CALL` spelling? | composes with caller's txn? | viable? |
|---|---|---|---|---|
| A — fresh `Connection`, no transaction | **no** | yes | no | no |
| B — calling `ClientContext` | n/a — **deadlocks** | yes | — | no |
| **A′ — fresh `Connection` + explicit `BEGIN`/`COMMIT`/`ROLLBACK`** | **yes** | **yes** | **no** | **yes** |
| **C — pragma query substitution** | **yes** | no — `PRAGMA` only | **yes** | **yes** |

**Recommendation: A′.** The decision is the coordinator's; the trade-off is one axis wide and
is set out in [The decision](#the-decision) below.

Measured against DuckDB `v1.5.5` (submodule `d8cdaa33fda`), duckent-ext at `caa48a6`.

---

## The question

Seven verbs — `tree_ddl_create`, `tree_ddl_drop`, `tree_ddl_alter`, `tree_insert`,
`tree_replace`, `tree_delete`, `tree_check` — each have to run the N statements their
compile macro returns as a `VARCHAR[]`. The compile macros emit **no transaction control**
(verified: `grep -c "BEGIN TRANSACTION" src/sql_macros/03_ddl.sql src/sql_macros/04_dml.sql`
→ `0`, `0`), because a compiler that emitted `BEGIN TRANSACTION` could not be executed from
inside a query at all. That was removed deliberately in the plan repo at `a21d889`, on the
core design's §4 principle that a mutating operation is "a pure compiler plus a thin
executor".

So the executor's own execution context is the **only** thing that can provide atomicity.
This is what each candidate actually did.

The reference behaviour is `Session.execute` in the plan repo's `test/run.py`: call the
compile macro, then run each statement inside one `BEGIN` / `COMMIT` with `ROLLBACK` on
error.

### One correction to the plan's stated theory

`run.py`'s comment predicts that for the C++ port "the enclosing single statement supplies the
same atomicity this block does" — i.e. mechanism B. **That prediction is wrong: B deadlocks.**
Neither surviving mechanism works the way the plan expected. A′ reproduces `run.py`'s
executor literally; C delegates the transaction to DuckDB.

## The probe

The deciding test is the one the plan repo's own `test/sql/00_smoke.test` already uses for
this property, so this reproduces an established test rather than inventing one. The compile
macro is overridden to a two-statement list whose **second statement raises**, so the first
must leave nothing behind:

```sql
CREATE OR REPLACE MACRO tree_compile_check(sch, nm) AS
  ['CREATE TABLE ' || nm || '(x INT)', 'SELECT error(''boom'')'];
```

A mechanism is atomic if, after the verb fails with `boom`, the table does not exist.

---

## Mechanism A — fresh `Connection`, no transaction

A `TableFunction` whose scan opens `Connection con(*context.db)` and runs the compile query
and then each statement on it, with no transaction around them.

**Result: NOT atomic. The first statement survived.**

```
D CALL tree_check_a('main','a_roll');
Invalid Input Error: boom
D SELECT count(*) AS a_rows_left FROM a_roll;
┌─────────────┐
│ a_rows_left │
│    int64    │
├─────────────┤
│           0 │
└─────────────┘
```

`a_roll` exists with zero rows: `CREATE TABLE` committed, then `SELECT error('boom')` raised,
and nothing undid the `CREATE`. A separate `Connection` has its own `ClientContext` and its
own transaction, and in autocommit each statement commits as it completes.

This form cannot pass the corpus — `00_smoke.test` requires `rolled_back` not to survive — so
it is superseded entirely by A′ below. It is recorded because confirming it was the point of
the spike, and because it isolates *which* ingredient supplies A′'s atomicity: the transaction,
not the side connection.

## Mechanism B — statements through the calling `ClientContext`

A `TableFunction` whose scan calls `context.Query(sql, false)` so the statements join the
transaction the `CALL` already opened.

**Result: DuckDB does not reject this with an error. It deadlocks.**

There is no error text to quote — that is the finding. The probe file was run alone under a
timeout:

```
$ timeout 90 ./build/release/test/unittest "test/sql/93_spike_executor_b.test" \
    --test-config test/test_config.json
Terminated
EXIT=124
```

All 16 threads of the hung process were blocked on a futex, i.e. a lock, not a spin and not a
swallowed exception:

```
tid=3115727 state=S wchan=futex_do_wait
tid=3115728 state=S wchan=futex_do_wait
... (16 of 16 identical)
```

Traced to source: `ClientContext::Query(const string &, QueryParameters)`
(`src/main/client_context.cpp:1041`) takes `auto lock = LockContext();` as its first
statement. `LockContext()` returns a `ClientContextLock`
(`src/include/duckdb/main/client_context.hpp:327`), which is a plain
`std::unique_lock` over `mutex context_lock`
(`src/include/duckdb/main/client_context.hpp:318`) — not recursive. The scan is itself running
inside `ExecutePendingQueryInternal(*lock, …)`, under that same lock. Re-entering is therefore
a self-deadlock.

It deadlocks on the **compile** query, before any statement in the list runs. Every public
`ClientContext` entry point that could run SQL — `Query`, `PendingQuery`, `Prepare`,
`RunFunctionInTransaction` — takes the same lock, so there is no variant of B that reaches the
caller's transaction through the public API.

**B is not viable.** It is worse than non-atomic: it hangs the session with no error. It is
also, per the correction above, the mechanism the plan assumed would be used.

## Mechanism A′ — fresh `Connection` with the executor's own transaction

A as above, plus the transaction `run.py`'s `Session.execute` puts there: `BEGIN TRANSACTION`,
the statements, `COMMIT`; on any statement error, `ROLLBACK` and rethrow the original error.
A fresh `Connection` is **not inside a query**, so `BEGIN TRANSACTION` is legal on it — the
prohibition that killed the compiler-emitted transactions does not apply to a side connection.
This is `run.py`'s executor transliterated into C++, which is what the plan says this layer is.

**Result: ATOMIC.** Registered under the corpus spelling `tree_check`, it passes the plan
repo's real `00_smoke.test` atomicity record verbatim — `CALL tree_check('main','rolled_back')`
raises `boom`, and `SELECT * FROM rolled_back` then errors `does not exist`:

```
$ ./build/release/test/unittest "test/sql/92_spike_executor.test" --test-config test/test_config.json
[1/1] (100%): test/sql/92_spike_executor.test
===============================================================================
All tests passed (6 assertions in 1 test case)
```

### A′ rolls back on parse- and bind-time errors too

The explicit `ROLLBACK` fires on *any* errored result, not only runtime ones. Measured on all
three error classes — in each case the `CREATE TABLE` did not survive:

```
D -- second statement is 'THIS IS NOT SQL'
D CALL tree_check('main','ap_parse');
Parser Error: syntax error at or near "THIS"
D SELECT count(*) FROM ap_parse;
Catalog Error: Table with name ap_parse does not exist!

D -- second statement is 'INSERT INTO no_such_table VALUES (1)'
D CALL tree_check('main','ap_bind');
Catalog Error: Table with name no_such_table does not exist!
D SELECT count(*) FROM ap_bind;
Catalog Error: Table with name ap_bind does not exist!

D -- three statements, the third raises
D CALL tree_check('main','ap_late');
Invalid Input Error: late
D SELECT count(*) FROM ap_late;
Catalog Error: Table with name ap_late does not exist!
```

Error text is preserved exactly, via `ErrorData::Throw()` after the rollback — no
double-wrapping of the message the corpus matches on.

### A′ does not conflict with or block on the caller's concurrent writes

A side connection writing while the caller's transaction holds uncommitted writes is an
obvious deadlock/conflict risk. Measured, and it does not materialise — neither for unrelated
objects nor for the *same* table:

```
D BEGIN TRANSACTION;
D CREATE TABLE caller_side(y INT);     -- caller holds an uncommitted catalog write
D CALL tree_check('main','ap_conflict');
D SELECT 'reached' AS got_here;        -- reached, no error, no hang
```

```
D BEGIN TRANSACTION;
D INSERT INTO shared_ledger VALUES (2);       -- caller writes the same table the verb writes
D CALL tree_check('main','whatever');         -- verb INSERTs 99 on its side connection
D SELECT 'reached' AS got_here;               -- reached
D ROLLBACK;
D SELECT n FROM shared_ledger ORDER BY n;
┌───────┐
│   n   │
├───────┤
│     1 │
│    99 │
└───────┘
```

No write-write conflict, no blocking. Note what the second case also shows: the caller's `2`
rolled back and the verb's `99` did not — the non-composition below, on a data table rather
than the catalog.

### A′'s weakness: it does not compose with the caller's transaction

The verb's work runs in a transaction of its own, so it **survives the caller's `ROLLBACK`**:

```
D BEGIN TRANSACTION;
D CALL tree_check('main','ap_in_txn');
D ROLLBACK;
D SELECT count(*) AS ap_rows_after_caller_rollback FROM ap_in_txn;
┌───────────────────────────────┐
│ ap_rows_after_caller_rollback │
│             int64             │
├───────────────────────────────┤
│                             1 │
└───────────────────────────────┘
```

This is the one axis on which C is genuinely better. See [The decision](#the-decision).

Worth noting that `run.py`'s executor **has the same limitation, and a worse version of it**:
it issues `BEGIN TRANSACTION` on the caller's own connection, which would simply error inside
an existing transaction. So composition is not behaviour this layer is specified to reproduce;
A′ is strictly more permissive than the reference, not less.

### A′'s second weakness: a scan's side effect can be elided

A mutating table function only mutates if its scan is actually executed, and the optimizer
decides that. Measured, by making the compiled statement `INSERT INTO hits VALUES (1)` and
counting `hits`:

| spelling | scan runs? | verb executes? |
|---|---|---|
| `CALL tree_check('main','x')` | once | **yes** — correct |
| `SELECT * FROM range(3) r, tree_check('main','x')` | once (not 3×) | yes, once — correct |
| `EXPLAIN SELECT * FROM tree_check('main','x')` | no | no — correct |
| `SELECT * FROM tree_check('main','x') LIMIT 0` | **no** | **no — silently does nothing** |

The corpus uses bare `CALL`, which is the correct row. But `LIMIT 0` silently skipping a
mutation is a real footgun that C does not have, because a pragma is a statement and is always
executed. Task 5 should note it; it is not reachable from the corpus' spelling.

## Mechanism C — pragma query substitution

Register the verb as a `PragmaFunction::PragmaCall(name, pragma_query_t, …)`. The handler
returns the compiled statements joined with `;`, and DuckDB parses and executes that text in
the caller's own transaction.

**Result: ATOMIC.**

```
D PRAGMA tree_check_c('main','c_roll');
Invalid Input Error: boom
D ROLLBACK;
D SELECT count(*) AS c_rows_left FROM c_roll;
Catalog Error: Table with name c_roll does not exist!
```

The success case commits normally:

```
D PRAGMA tree_check_c('main','c_ok');     -- list is CREATE TABLE + INSERT VALUES (7)
D SELECT x AS c_ok_value FROM c_ok;
┌────────────┐
│ c_ok_value │
│   int32    │
├────────────┤
│          7 │
└────────────┘
```

### C composes with the caller's transaction — A′'s weakness, inverted

The verb genuinely joins the caller's transaction rather than merely having one of its own, so
the caller's `ROLLBACK` undoes it:

```
D BEGIN TRANSACTION;
D PRAGMA tree_check_c('main','c_in_txn');
D ROLLBACK;
D SELECT count(*) AS c_rows_after_caller_rollback FROM c_in_txn;
Catalog Error: Table with name c_in_txn does not exist!
```

And the caller's own concurrent work rolls back together with the verb's partial work:

```
D BEGIN TRANSACTION;
D CREATE TABLE caller_side(y INT);
D PRAGMA tree_check_c('main','c_in_txn');
Invalid Input Error: boom
D ROLLBACK;
D SELECT count(*) FROM c_in_txn;     -> Catalog Error: ... does not exist!
D SELECT count(*) FROM caller_side;  -> Catalog Error: ... does not exist!
```

### Why it is atomic — the mechanism in source

`StatementPreprocessor::TryReparsePragma` (`src/planner/statement_preprocessor.cpp:107`) calls
the `pragma_query_t`, re-parses the returned text into N statements, and hands them to
`AddStatements` (`:32`). `GetTransactionHandling` (`:74`) then decides, and this is the part
that supplies the atomicity:

- caller in autocommit, N > 1 → `WRAP_IN_TRANSACTION`: DuckDB prepends a real
  `BEGIN TRANSACTION` and appends `COMMIT`, both with
  `TransactionInvalidationPolicy::ALL_ERRORS_INVALIDATE_TRANSACTION`.
- caller already in a transaction → `SET current_transaction_invalidation_policy =
  'ALL_ERRORS_INVALIDATE_TRANSACTION'` around the body, restored afterwards.

So the transaction is DuckDB's, not duckent's, and duckent emits no transaction control
anywhere — in the macros or in C++.

`ALL_ERRORS_INVALIDATE_TRANSACTION` also rolls back on parse- and bind-time errors. Measured:

```
D PRAGMA tree_check_c('main','c_roll');
Parser Error: syntax error at or near "boom"
D SELECT count(*) FROM c_roll;
Catalog Error: Table with name c_roll does not exist!
```

**This is not a discriminator** — A′ was measured to do the same, via its explicit `ROLLBACK`
on any errored result. It was expected to favour C and does not.

### Precedent

`PRAGMA import_database('dir')` (`src/function/pragma/pragma_queries.cpp:156`, registered at
`:231`) is a `pragma_query_t` that reads `schema.sql` and `load.sql` and returns their
concatenated statements for DuckDB to execute atomically. duckent's verbs are structurally
identical.

### C's cost: `CALL` does not reach a pragma function

```
D CALL tree_check_c('main', 'viacall');
Catalog Error: Table Function with name tree_check_c does not exist!
Did you mean "tree_check_a"?
```

This is structural, not a lookup quirk, and cannot be worked around:

- `Transformer::TransformCall` (`src/parser/transform/statement/transform_call.cpp`)
  unconditionally produces a `CallStatement`.
- `Binder::Bind(CallStatement &)` (`src/planner/binder/statement/bind_call.cpp`) rewrites it
  into `SELECT * FROM <table_function_ref>`.
- that ref is resolved only as `CatalogType::TABLE_FUNCTION_ENTRY`
  (`src/planner/binder/tableref/bind_table_function.cpp:368`). No pragma fallback exists.
- the preprocessing stage where statement substitution and transaction wrapping happen is
  reachable only from `StatementType::PRAGMA_STATEMENT` and `StatementType::MULTI_STATEMENT`,
  and `MultiStatement` is produced only by the transformer itself (PIVOT, multi-action ALTER
  TABLE) — never by an extension.

DuckDB itself acknowledges the asymmetry: the *opposite* mistake already gets a courtesy
message, `"Pragma Function with name %s does not exist, but a table function with the same
name exists, try `CALL %s(...)`"` (`src/planner/binder/statement/bind_pragma.cpp:41`).

So choosing C means moving every invocation to `PRAGMA verb(...)`: ~250 sites across 20 files
in the corpus (`CALL tree_ddl_create` × 187, `tree_ddl_alter` × 26, `tree_insert` × 17,
`tree_check` × 9, `tree_delete` × 4, `tree_ddl_drop` × 4, `tree_replace` × 3), plus
`run.py`'s `CALL_RE`, plus the README, the cheatsheet, the handover and the three design
specs, which all document `CALL tree_ddl_create(...)` as duckent's surface.

If C is chosen anyway, the confusing failure at old call sites can be fixed: a
`PragmaFunction` and a `TableFunction` may share a name, and a throwing bind on the table
function turns "does not exist" into an instruction. Measured:

```
D CALL tree_check_e('main','e_via_call');
Binder Error: tree_check_e must be invoked as PRAGMA tree_check_e(...), not CALL: a CALL runs
inside a query, where the compiled statement list cannot be executed atomically
```

---

## Not a discriminator: compile reads committed state only

Both surviving mechanisms compile the macro on a side `Connection`, and so neither can see the
caller's **uncommitted** state. For C this is forced: the `pragma_query_t` handler runs inside
`StatementPreprocessor::Preprocess` → `RunFunctionInTransactionInternal(lock, …)`, which
already holds the context lock, so the compile step cannot use `context.Query` either — the
same reason B cannot. For A′ it follows from the side connection.

Measured for **both**. The caller inserts rows inside an open transaction, and the compile
macro embeds `(SELECT count(*) FROM seen)` in the name it generates:

```
D BEGIN TRANSACTION;
D INSERT INTO seen VALUES (2);
D INSERT INTO seen VALUES (3);
D SELECT count(*) AS caller_sees FROM seen;      ->  3

D CALL tree_check('main','ap');                  -- A'
D SELECT table_name FROM duckdb_tables() WHERE table_name LIKE 'ap\_%' ESCAPE '\';
   ->  ap_1          (not ap_3)

D PRAGMA tree_check_e('main','u');               -- C
D SELECT table_name FROM duckdb_tables() WHERE table_name LIKE 'u\_%' ESCAPE '\';
   ->  u_1           (not u_3)
```

The caller saw 3; compilation saw 1, under both. **In an explicit transaction, a verb compiles
against state as of the transaction's start, not against what the transaction has done so
far** — identically for A′ and C, so this does not choose between them.

Consequences, which Task 5 inherits either way:

- **Autocommit — the corpus' usage — is unaffected.** Each verb is its own transaction, so
  there is no uncommitted state to miss.
- `BEGIN; <verb> tree_ddl_create(a); <verb> tree_ddl_create(b, like := a); COMMIT;` would
  mis-compile, because `b`'s compile would not see `a`'s `tree_catalog` rows. This is
  *compile-time staleness*, not an atomicity defect, and must be documented as unsupported or
  detected and refused.

There is no public API that avoids it. The expression-binder route used by
`Binder::BindPragma` to evaluate pragma arguments in the caller's transaction will not serve,
because `ConstantBinder` rejects subqueries outright —
`throw BinderException(clause + " cannot contain subqueries")`
(`src/planner/expression_binder/constant_binder.cpp:25`) — and the real compile macros contain
them (e.g. `tree_compile_create` has
`EXISTS (SELECT 1 FROM tree_catalog.trees t WHERE …)`, `src/sql_macros/03_ddl.sql:119`).

---

## The decision

Both A′ and C give **all-or-nothing execution of the statement list**. Three of the four axes
that looked like discriminators turned out not to be: parse/bind-time rollback (both),
compile staleness (both), and conflict/blocking risk (neither). The choice is one axis wide:

- **A′ keeps `CALL`.** Zero corpus change, zero spec/README/cheatsheet change. ~10 lines of
  C++. But a verb inside a caller's explicit transaction commits regardless of the caller's
  `ROLLBACK`.
- **C composes with the caller's transaction.** But it costs the `PRAGMA` spelling everywhere
  duckent is invoked or documented.

**Recommendation: A′**, for three reasons.

1. **Composition is not behaviour this layer is specified to reproduce.** `run.py`'s
   `Session.execute` issues `BEGIN TRANSACTION` on the caller's own connection, which cannot
   nest — the reference executor does not support a verb inside a caller's transaction at all.
   C's advantage is over-delivery against the spec; A′'s limitation is the reference's own.
2. **The corpus already encodes the choice.** `00_smoke.test` requires atomicity *and* spells
   every verb `CALL`. A′ satisfies both as written; C satisfies the first by changing the
   second in ~250 places and in every document that describes duckent.
3. **A′ is the reversible choice.** Moving A′ → C later is a one-file change in the extension
   plus the corpus migration — the same cost C has today, deferred. Moving C → A′ later means
   migrating the corpus back. Choosing A′ keeps the option; choosing C spends it immediately.

A′'s non-composition should not be left silent, which is the one thing that would make it the
"half-works" outcome the spike exists to prevent. `ClientContext::transaction` is public
(`client_context.hpp:91`) and `TransactionContext::IsAutoCommit()`
(`transaction_context.hpp:50`) distinguishes an implicit statement-level transaction from an
explicit `BEGIN`, so the executor can **detect and refuse** a verb inside an explicit
transaction with a clear error instead of silently not composing. API verified by inspection;
the guard's behaviour is not measured and is a Task 5 item.

### For Task 5, if A′ is chosen

1. Register each of the seven verbs as a `TableFunction` under its existing `CALL` name.
2. In the scan: compile on `Connection con(*context.db)`, then `BEGIN TRANSACTION`, the
   statements, `COMMIT`; on any errored result `ROLLBACK` and rethrow via
   `ErrorData::Throw()` so the corpus' expected error text is preserved verbatim.
3. Emit **no** `BEGIN`/`COMMIT` in any `.sql` macro — the transaction lives in the executor,
   which is where `a21d889` moved it.
4. Refuse when `!context.transaction.IsAutoCommit()`, rather than silently not composing.
   This also covers the compile-staleness case, since both arise only inside an explicit
   transaction.
5. Note the `LIMIT 0` scan-elision footgun; it is not reachable from the corpus' `CALL`
   spelling.

### For Task 5, if C is chosen instead

1. Register each verb as `PragmaFunction::PragmaCall(name, handler, …)`, plus a same-named
   `TableFunction` whose bind throws the "use PRAGMA" `BinderException`.
2. Compile on a side `Connection`; emit no transaction control.
3. The corpus, `run.py`'s `CALL_RE`, and the documented surface move to `PRAGMA`.
4. Handle or refuse the compile-staleness case.

## Reproducing

The probe code was throwaway and is **not committed**. Round 1 registered `tree_check_a/b/c/e`
and round 2 registered `tree_check` (A′) and `tree_check_c` (C); Task 5 replaces them with the
real verbs, and the atomicity assertions duplicate the `tree_compile_check` rollback case in
the plan repo's `test/sql/00_smoke.test` that Task 6 adds. Nothing was left behind in
`test/sql/`; `make test` is unchanged at 7 assertions in 2 test cases, and the clean tree
rebuilds green.

To reproduce: add a source registering the shapes above, then run the two-statement
failing-list probe against each. Mechanism B must be run alone and under a timeout — it hangs.
