-- ============================================================================
-- 01_build_star_schema.sql (Type-Casted & Hardened)
-- ============================================================================

-- STEP 1: STAGING
CREATE OR REPLACE TEMP TABLE stage_patients AS 
SELECT * FROM read_csv_auto('data/raw/patients.csv', ignore_errors=true);

CREATE OR REPLACE TEMP TABLE stage_encounters AS 
SELECT * FROM read_csv_auto('data/raw/encounters.csv', ignore_errors=true);

CREATE OR REPLACE TEMP TABLE stage_providers AS 
SELECT * FROM read_csv_auto('data/raw/providers.csv', ignore_errors=true);

CREATE OR REPLACE TEMP TABLE stage_organizations AS 
SELECT * FROM read_csv_auto('data/raw/organizations.csv', ignore_errors=true);


-- STEP 2: DIMENSIONS WITH EXPLICIT VARCHAR CASTING

-- Dim_Patient
CREATE OR REPLACE TABLE Dim_Patient AS
SELECT
    COALESCE(TRIM(Id::VARCHAR), 'UNKNOWN') AS PatientKey,
    COALESCE(NULLIF(TRIM(FIRST::VARCHAR), ''), 'Unknown') AS FirstName,
    COALESCE(NULLIF(TRIM(LAST::VARCHAR), ''), 'Unknown') AS LastName,
    COALESCE(NULLIF(UPPER(TRIM(GENDER::VARCHAR)), ''), 'U') AS Gender,
    COALESCE(NULLIF(TRIM(RACE::VARCHAR), ''), 'Unknown') AS Race,
    COALESCE(NULLIF(TRIM(ETHNICITY::VARCHAR), ''), 'Unknown') AS Ethnicity,
    TRY_CAST(BIRTHDATE AS DATE) AS BirthDate,
    TRY_CAST(DEATHDATE AS DATE) AS DeathDate,
    
    CASE 
        WHEN TRY_CAST(BIRTHDATE AS DATE) IS NULL OR TRY_CAST(BIRTHDATE AS DATE) > CURRENT_DATE THEN NULL
        ELSE DATE_DIFF('year', TRY_CAST(BIRTHDATE AS DATE), COALESCE(TRY_CAST(DEATHDATE AS DATE), CURRENT_DATE))
    END AS Age,
    
    CASE 
        WHEN TRY_CAST(BIRTHDATE AS DATE) IS NULL OR TRY_CAST(BIRTHDATE AS DATE) > CURRENT_DATE THEN 'Unknown'
        WHEN DATE_DIFF('year', TRY_CAST(BIRTHDATE AS DATE), COALESCE(TRY_CAST(DEATHDATE AS DATE), CURRENT_DATE)) < 18 THEN '0-17'
        WHEN DATE_DIFF('year', TRY_CAST(BIRTHDATE AS DATE), COALESCE(TRY_CAST(DEATHDATE AS DATE), CURRENT_DATE)) BETWEEN 18 AND 40 THEN '18-40'
        WHEN DATE_DIFF('year', TRY_CAST(BIRTHDATE AS DATE), COALESCE(TRY_CAST(DEATHDATE AS DATE), CURRENT_DATE)) BETWEEN 41 AND 65 THEN '41-65'
        ELSE '66+'
    END AS AgeGroup,
    
    COALESCE(NULLIF(TRIM(CITY::VARCHAR), ''), 'Unknown') AS City,
    COALESCE(NULLIF(TRIM(STATE::VARCHAR), ''), 'Unknown') AS State,
    COALESCE(NULLIF(TRIM(ZIP::VARCHAR), ''), '00000') AS ZipCode
FROM stage_patients
WHERE TRIM(Id::VARCHAR) IS NOT NULL AND TRIM(Id::VARCHAR) != '';

-- Unknown Member Record
INSERT INTO Dim_Patient (PatientKey, FirstName, LastName, Gender, Race, Ethnicity, AgeGroup, City, State, ZipCode)
VALUES ('UNKNOWN', 'Unknown', 'Patient', 'U', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', '00000');


-- Dim_Provider
CREATE OR REPLACE TABLE Dim_Provider AS
SELECT
    COALESCE(TRIM(p.Id::VARCHAR), 'UNKNOWN') AS ProviderKey,
    COALESCE(NULLIF(TRIM(p.NAME::VARCHAR), ''), 'Unknown Provider') AS ProviderName,
    COALESCE(NULLIF(UPPER(TRIM(p.GENDER::VARCHAR)), ''), 'U') AS Gender,
    COALESCE(NULLIF(TRIM(p.SPECIALITY::VARCHAR), ''), 'General Practice') AS Specialty,
    COALESCE(NULLIF(TRIM(o.NAME::VARCHAR), ''), 'Unassigned Facility') AS OrganizationName,
    COALESCE(NULLIF(TRIM(o.CITY::VARCHAR), ''), 'Unknown') AS OrganizationCity
FROM stage_providers p
LEFT JOIN stage_organizations o ON TRIM(p.ORGANIZATION::VARCHAR) = TRIM(o.Id::VARCHAR)
WHERE TRIM(p.Id::VARCHAR) IS NOT NULL AND TRIM(p.Id::VARCHAR) != '';

-- Unknown Member Record
INSERT INTO Dim_Provider (ProviderKey, ProviderName, Gender, Specialty, OrganizationName, OrganizationCity)
VALUES ('UNKNOWN', 'Unknown Provider', 'U', 'General Practice', 'Unassigned Facility', 'Unknown');


-- Dim_Date
CREATE OR REPLACE TABLE Dim_Date AS
WITH date_bounds AS (
    SELECT 
        COALESCE(MIN(TRY_CAST(START AS DATE)), '2010-01-01'::DATE) AS min_date,
        COALESCE(MAX(TRY_CAST(STOP AS DATE)), CURRENT_DATE) AS max_date
    FROM stage_encounters
)
SELECT
    d::DATE AS DateKey,
    YEAR(d) AS Year,
    MONTH(d) AS Month,
    MONTHNAME(d) AS MonthName,
    QUARTER(d) AS Quarter,
    'Q' || QUARTER(d) AS QuarterName,
    DAYOFWEEK(d) AS DayOfWeek,
    DAYNAME(d) AS DayName,
    CASE WHEN DAYOFWEEK(d) IN (0, 6) THEN TRUE ELSE FALSE END AS IsWeekend
FROM date_bounds,
UNNEST(generate_series(min_date, max_date, INTERVAL 1 DAY)) AS t(d);


-- STEP 3: SANITIZED FACT TABLE
CREATE OR REPLACE TABLE Fact_Encounters AS
WITH clean_encounters AS (
    SELECT
        TRIM(e.Id::VARCHAR) AS EncounterKey,
        
        COALESCE(p.PatientKey, 'UNKNOWN') AS PatientKey,
        COALESCE(pr.ProviderKey, 'UNKNOWN') AS ProviderKey,
        
        TRY_CAST(e.START AS TIMESTAMP) AS AdmitTimestamp,
        TRY_CAST(e.STOP AS TIMESTAMP) AS DischargeTimestamp,
        TRY_CAST(e.START AS DATE) AS AdmitDateKey,
        TRY_CAST(e.STOP AS DATE) AS DischargeDateKey,
        
        COALESCE(NULLIF(TRIM(e.ENCOUNTERCLASS::VARCHAR), ''), 'Other') AS EncounterClass,
        COALESCE(NULLIF(TRIM(e.CODE::VARCHAR), ''), 'N/A') AS ReasonCode,
        COALESCE(NULLIF(TRIM(e.DESCRIPTION::VARCHAR), ''), 'Unspecified Encounter') AS EncounterDescription,
        
        GREATEST(0.0, COALESCE(TRY_CAST(e.BASE_ENCOUNTER_COST AS DOUBLE), 0.0)) AS BaseCost,
        GREATEST(0.0, COALESCE(TRY_CAST(e.TOTAL_CLAIM_COST AS DOUBLE), 0.0)) AS TotalCost,
        GREATEST(0.0, COALESCE(TRY_CAST(e.PAYER_COVERAGE AS DOUBLE), 0.0)) AS PayerCoverage,
        
        CASE 
            WHEN TRY_CAST(e.STOP AS TIMESTAMP) < TRY_CAST(e.START AS TIMESTAMP) THEN 0.0
            ELSE ROUND(DATE_DIFF('minute', TRY_CAST(e.START AS TIMESTAMP), TRY_CAST(e.STOP AS TIMESTAMP)) / 60.0, 2)
        END AS LengthOfStayHours,
        
        CASE 
            WHEN TRY_CAST(e.STOP AS TIMESTAMP) < TRY_CAST(e.START AS TIMESTAMP) THEN 1
            ELSE GREATEST(1, DATE_DIFF('day', TRY_CAST(e.START AS DATE), TRY_CAST(e.STOP AS DATE)))
        END AS LengthOfStayDays

    FROM stage_encounters e
    LEFT JOIN Dim_Patient p ON TRIM(e.PATIENT::VARCHAR) = p.PatientKey
    LEFT JOIN Dim_Provider pr ON TRIM(e.PROVIDER::VARCHAR) = pr.ProviderKey
    WHERE TRIM(e.Id::VARCHAR) IS NOT NULL AND TRIM(e.Id::VARCHAR) != ''
      AND TRY_CAST(e.START AS TIMESTAMP) IS NOT NULL
),
readmission_calculation AS (
    SELECT
        c.*,
        LEAD(c.AdmitTimestamp) OVER (
            PARTITION BY c.PatientKey 
            ORDER BY c.AdmitTimestamp
        ) AS NextAdmitTimestamp
    FROM clean_encounters c
)
SELECT
    r.EncounterKey,
    r.PatientKey,
    r.ProviderKey,
    r.AdmitDateKey,
    r.DischargeDateKey,
    r.AdmitTimestamp,
    r.DischargeTimestamp,
    r.EncounterClass,
    r.ReasonCode,
    r.EncounterDescription,
    r.BaseCost,
    r.TotalCost,
    r.PayerCoverage,
    r.LengthOfStayHours,
    r.LengthOfStayDays,
    
    CASE WHEN LOWER(r.EncounterClass) IN ('emergency', 'urgent') THEN TRUE ELSE FALSE END AS IsEmergency,
    
    CASE 
        WHEN r.NextAdmitTimestamp >= r.DischargeTimestamp 
        THEN DATE_DIFF('day', r.DischargeTimestamp, r.NextAdmitTimestamp)
        ELSE NULL 
    END AS DaysToNextAdmit,
    
    CASE 
        WHEN r.NextAdmitTimestamp >= r.DischargeTimestamp 
         AND DATE_DIFF('day', r.DischargeTimestamp, r.NextAdmitTimestamp) BETWEEN 0 AND 30 
        THEN TRUE 
        ELSE FALSE 
    END AS IsReadmitted30Days
FROM readmission_calculation r;


COPY Dim_Patient TO 'data/parquets/Dim_Patient.parquet' (FORMAT PARQUET);
COPY Dim_Provider TO 'data/parquets/Dim_Provider.parquet' (FORMAT PARQUET);
COPY Dim_Date TO 'data/parquets/Dim_Date.parquet' (FORMAT PARQUET);
COPY Fact_Encounters TO 'data/parquets/Fact_Encounters.parquet' (FORMAT PARQUET);