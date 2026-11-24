-- ICT371 Question 10: Scholarship Application Assessment (PostgreSQL)
DROP VIEW IF EXISTS v_approved_applicants;
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables and constraints
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(15) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(15) NOT NULL,
    new_status     VARCHAR(15) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- (b) Function: evaluate scholarship eligibility
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income, and mark must not be NULL.';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age (%) must be positive.', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income (%) cannot be negative.', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark (%) must be between 0 and 100.', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000.00)
       AND (p_mark >= 70.00);
END;
$$;

-- (c) Procedure: assess a single PENDING application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_age    INT;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
    v_status VARCHAR(15);
    v_new    VARCHAR(15);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications WHERE application_id = p_application_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application ID: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (current status: %).', p_application_id, v_status;
    END IF;

    v_new := CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark) THEN 'APPROVED' ELSE 'REJECTED' END;

    UPDATE applications SET status = v_new WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger: audit actual status transitions
CREATE OR REPLACE FUNCTION fn_trg_decision_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_status_audit
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION fn_trg_decision_audit();

-- (a) Seed data: 3 students, 6 PENDING applications (qualifying, non-qualifying, boundary cases)
INSERT INTO students (student_number, full_name) VALUES
('2025001', 'Natasha Banda'),
('2025002', 'Kelvin Mwansa'),
('2025003', 'Esther Tembo');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
(1, 18, 3000.00, 70.00, CURRENT_DATE - 5, 'PENDING'), -- Exact lower/upper boundary (APPROVED)
(1, 25, 1800.00, 84.50, CURRENT_DATE - 4, 'PENDING'), -- Exact upper age boundary (APPROVED)
(2, 17, 1500.00, 88.00, CURRENT_DATE - 3, 'PENDING'), -- Underage 17 (REJECTED)
(2, 22, 3000.01, 79.00, CURRENT_DATE - 2, 'PENDING'), -- Income just over K3,000 (REJECTED)
(3, 20, 2200.00, 69.99, CURRENT_DATE - 1, 'PENDING'), -- Mark just below 70 (REJECTED)
(3, 21, 2500.00, 76.00, CURRENT_DATE,     'PENDING'); -- Qualifying standard case (APPROVED)

-- (e) View: approved applicants without exposing household income
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index & EXPLAIN
-- Justification: Composite index on (status, submitted_on) filters by exact status first
-- and then performs an ordered range scan on submitted_on.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

EXPLAIN ANALYZE
SELECT application_id, student_id, average_mark, submitted_on
FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job: batch assess PENDING applications every Monday at 08:00
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
SELECT * FROM v_approved_applicants;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('weekly_scholarship_assessment', '0 8 * * 1', $$CALL pr_assess_pending();$$);
