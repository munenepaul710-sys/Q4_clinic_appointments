-- =====================================================================
-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- Dialect: PostgreSQL (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Slots: 09:00, 10:00, 11:00, 12:00. Statuses: BOOKED, ATTENDED, CANCELLED.
-- =====================================================================

-- (a) DATABASE AND SEED DATA ------------------------------------------
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

CREATE TABLE patients (
    patient_id SERIAL       PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL       PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL      PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients (patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors (doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL
                    CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
                    CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE    PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

INSERT INTO patients (full_name) VALUES
    ('Chanda Mwila'), ('Mutale Banda'), ('Natasha Phiri');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Kabwe Mumba'), ('Dr. Esther Zimba'), ('Dr. Joseph Sakala');

-- (d) TRIGGER (installed before seed data so the slot rule is enforced) -
CREATE OR REPLACE FUNCTION trg_fn_slot_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              -- On UPDATE, exclude the appointment being changed
              AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Doctor % is already booked on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_slot_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_slot_clash();

-- Optional safety net against two sessions booking at the same instant:
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

-- Six appointments (no slot clashes). Includes today's BOOKED ones for (e).
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED'),
    (3, 2, CURRENT_DATE - 1, '09:00', 'CANCELLED'),
    (1, 2, CURRENT_DATE,     '10:00', 'BOOKED'),
    (2, 3, CURRENT_DATE,     '11:00', 'BOOKED'),
    (3, 1, CURRENT_DATE + 1, '12:00', 'BOOKED');

-- (b) FUNCTION ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;        -- zero when the day has no bookings
END;
$$;

SELECT fn_daily_load(1, CURRENT_DATE - 1) AS load_two;
SELECT fn_daily_load(3, CURRENT_DATE + 30) AS load_zero;

-- (c) PROCEDURE --------------------------------------------------------
-- Slot clashes are rejected by the trigger in (d).
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER, p_doctor_id INTEGER, p_day DATE, p_slot TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or NULL', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

CALL pr_book_appointment(3, 3, CURRENT_DATE + 2, '09:00');   -- valid
-- CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '09:00'); -- clash: rejected by trigger
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00'); -- past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE + 2, '13:00'); -- unsupported slot
-- CALL pr_book_appointment(9, 1, CURRENT_DATE + 2, '09:00'); -- unknown patient

-- (e) VIEW -------------------------------------------------------------
-- Only the names and slot are exposed; no other patient data.
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) INDEX ------------------------------------------------------------
-- Justification: the clinic searches by day and doctor (for example, a
-- doctor's schedule for a day). A non-unique composite index on
-- (appointment_day, doctor_id) serves that lookup directly, and the day
-- column also supports the daily summary job.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;   -- only so the plan is visible on a tiny table
EXPLAIN
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 2;
RESET enable_seqscan;

-- (g) SCHEDULED JOB ----------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;     -- rerun replaces the row
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);       -- rerun: still one row
SELECT * FROM clinic_summary;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_clinic_summary_daily',
    '0 1 * * *',                                        -- every day at 01:00
    $job$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$job$
);
