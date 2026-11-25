-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- Name: Nawa Sumbwanyambe | Student number: 202308788
-- DBMS: PostgreSQL (PL/pgSQL; scheduling with the pg_cron extension)

DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- ==== (a) Database: create the tables
CREATE TABLE students (
    student_id     SERIAL       PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL        PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL      PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

-- ==== (b) Function fn_scholarship_eligible
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25      -- inclusive
       AND p_income <= 3000             -- at most K3,000
       AND p_mark   >= 70;              -- at least 70
END;
$$;

-- ==== (c) Procedure pr_assess_application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age    INTEGER;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
    v_status VARCHAR(10);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;                                -- lock: two sessions cannot assess the same row

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_status;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                      THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- ==== (d) Trigger: AFTER UPDATE logging real status changes
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- ==== (e) View v_approved_applicants (no household income exposed)
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ==== (f) Index for status within a submitted_on date range
-- Equality column (status) first, range column (submitted_on) second.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

-- ==== (g) Scheduled job: pr_assess_pending (query FOR loop over PENDING applications only)
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'               -- completed applications are never touched
        ORDER BY application_id
        FOR UPDATE                             -- keep them locked until assessed
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

-- Requires: CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'assess_pending_weekly',
    '0 8 * * 1',                               -- every Monday at 08:00
    $$CALL pr_assess_pending()$$
);

-- ==== (a) Seed data: 3 students, 6 PENDING applications incl. boundary cases
INSERT INTO students (student_number, full_name) VALUES
    ('202500001', 'Mercy Zimba'),
    ('202500002', 'Patrick Musonda'),
    ('202500003', 'Linda Chibwe');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 18, 3000.00, 70.00, '2026-11-02'),   -- 1 qualifies: every boundary exactly met
    (1, 25, 2500.00, 85.50, '2026-11-05'),   -- 2 qualifies: upper age boundary
    (2, 17, 1000.00, 90.00, '2026-11-10'),   -- 3 fails: too young
    (2, 26, 1000.00, 90.00, '2026-11-12'),   -- 4 fails: too old
    (3, 22, 3000.01, 88.00, '2026-11-15'),   -- 5 fails: income just above K3,000
    (3, 22, 2000.00, 69.99, '2026-11-18');   -- 6 fails: mark just below 70

SELECT * FROM students ORDER BY student_id;
SELECT * FROM applications ORDER BY application_id;

-- ==== (b) Function tests (boundaries and invalid input)
SELECT * FROM (VALUES
    (18, 3000.00, 70.00), (25, 3000.00, 70.00), (17, 100, 80), (26, 100, 80),
    (20, 3000.01, 80),    (20, 100, 69.99),     (20, 0, 100)
) AS t(age, income, mark),
LATERAL (SELECT fn_scholarship_eligible(t.age, t.income, t.mark) AS eligible) e;
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 100, 80); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 100, 80);    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, -1);   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (c) Procedure tests
CALL pr_assess_application(1);                       -- boundary case -> APPROVED
CALL pr_assess_application(3);                       -- too young    -> REJECTED
DO $$ BEGIN CALL pr_assess_application(99); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(1);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;  -- already assessed
SELECT application_id, status FROM applications ORDER BY application_id;

-- ==== (d) Trigger tests
SELECT audit_id, application_id, old_status, new_status, changed_at IS NOT NULL AS has_timestamp
FROM decision_audit ORDER BY audit_id;               -- one row per real status change
UPDATE applications SET submitted_on = '2026-11-16' WHERE application_id = 5;   -- not a status change
UPDATE applications SET status = status WHERE application_id = 5;        -- same status
SELECT COUNT(*) AS audit_rows_still_2 FROM decision_audit;

-- ==== (e) View: APPROVED only, no income
SELECT * FROM v_approved_applicants ORDER BY student_number;

-- ==== (f) EXPLAIN
ANALYZE applications;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index plan
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- ==== (g) Run the weekly job, then rerun it: no reassessment, no duplicate audit rows
CALL pr_assess_pending();
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT COUNT(*) AS audit_rows_after_first_run FROM decision_audit;           -- 6 (one per application)
CALL pr_assess_pending();                                                    -- rerun: nothing PENDING left
SELECT COUNT(*) AS audit_rows_after_rerun FROM decision_audit;               -- still 6
SELECT * FROM v_approved_applicants ORDER BY student_number;
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'assess_pending_weekly';
