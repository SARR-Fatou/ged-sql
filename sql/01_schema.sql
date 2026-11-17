-- =====================================================================
-- GED (Gestion Électronique de Documents) d'un service administratif
-- 01 — Schéma : tables, contraintes et index (PostgreSQL)
-- =====================================================================

DROP SCHEMA IF EXISTS ged CASCADE;
CREATE SCHEMA ged;
SET search_path TO ged;

-- Types énumérés : garantissent que seules les valeurs prévues sont saisies
CREATE TYPE role_agent      AS ENUM ('agent', 'responsable', 'administrateur');
CREATE TYPE statut_dossier  AS ENUM ('ouvert', 'en_cours', 'clos');
CREATE TYPE statut_document AS ENUM ('brouillon', 'valide', 'archive');
CREATE TYPE niveau_confid   AS ENUM ('public', 'interne', 'confidentiel');
CREATE TYPE action_histo    AS ENUM ('creation', 'modification', 'validation', 'archivage', 'consultation', 'suppression');

-- ---------------------------------------------------------------------
-- Référentiels
-- ---------------------------------------------------------------------
CREATE TABLE service (
    service_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        VARCHAR(10)  NOT NULL UNIQUE,
    libelle     VARCHAR(100) NOT NULL
);

CREATE TABLE agent (
    agent_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nom         VARCHAR(60)  NOT NULL,
    prenom      VARCHAR(60)  NOT NULL,
    email       VARCHAR(120) NOT NULL UNIQUE CHECK (email LIKE '%_@_%._%'),
    role        role_agent   NOT NULL DEFAULT 'agent',
    service_id  SMALLINT     NOT NULL REFERENCES service(service_id),
    actif       BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE type_document (
    type_id                SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    libelle                VARCHAR(80)   NOT NULL UNIQUE,
    duree_conservation_ans SMALLINT      NOT NULL CHECK (duree_conservation_ans BETWEEN 1 AND 100),
    confidentialite        niveau_confid NOT NULL DEFAULT 'interne'
);

-- Pièces obligatoires selon le service (association MERISE « exiger »)
CREATE TABLE piece_obligatoire (
    service_id  SMALLINT NOT NULL REFERENCES service(service_id) ON DELETE CASCADE,
    type_id     SMALLINT NOT NULL REFERENCES type_document(type_id),
    PRIMARY KEY (service_id, type_id)
);

CREATE TABLE mot_cle (
    mot_cle_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    libelle     VARCHAR(50) NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- Données métier
-- ---------------------------------------------------------------------
CREATE TABLE usager (
    usager_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference   VARCHAR(20) NOT NULL UNIQUE,      -- identifiant fonctionnel, ex. USG-000123
    nom         VARCHAR(60) NOT NULL,
    prenom      VARCHAR(60) NOT NULL,
    ville       VARCHAR(80)
);

CREATE TABLE dossier (
    dossier_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero         VARCHAR(20)    NOT NULL UNIQUE, -- ex. ETC-2026-00042
    usager_id      INTEGER        NOT NULL REFERENCES usager(usager_id),
    service_id     SMALLINT       NOT NULL REFERENCES service(service_id),
    agent_id       INTEGER        REFERENCES agent(agent_id),   -- agent en charge
    objet          VARCHAR(200)   NOT NULL,
    statut         statut_dossier NOT NULL DEFAULT 'ouvert',
    date_ouverture DATE           NOT NULL DEFAULT CURRENT_DATE,
    date_cloture   DATE,
    CONSTRAINT dossier_cloture_coherente CHECK (
        (statut = 'clos' AND date_cloture IS NOT NULL AND date_cloture >= date_ouverture)
        OR (statut <> 'clos' AND date_cloture IS NULL)
    )
);

CREATE TABLE document (
    document_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dossier_id   INTEGER         NOT NULL REFERENCES dossier(dossier_id) ON DELETE CASCADE,
    type_id      SMALLINT        NOT NULL REFERENCES type_document(type_id),
    titre        VARCHAR(200)    NOT NULL,
    nom_fichier  VARCHAR(255)    NOT NULL,
    format       VARCHAR(10)     NOT NULL CHECK (format IN ('pdf', 'jpg', 'png', 'docx', 'xlsx', 'odt')),
    taille_ko    INTEGER         NOT NULL CHECK (taille_ko > 0 AND taille_ko <= 51200),  -- 50 Mo max
    empreinte    CHAR(64),       -- SHA-256 du fichier : détecte les doublons et les altérations
    version      SMALLINT        NOT NULL DEFAULT 1 CHECK (version >= 1),
    statut       statut_document NOT NULL DEFAULT 'brouillon',
    depose_par   INTEGER         NOT NULL REFERENCES agent(agent_id),
    date_depot   TIMESTAMPTZ     NOT NULL DEFAULT now(),
    date_maj     TIMESTAMPTZ     NOT NULL DEFAULT now()
);

CREATE TABLE document_mot_cle (
    document_id BIGINT  NOT NULL REFERENCES document(document_id) ON DELETE CASCADE,
    mot_cle_id  INTEGER NOT NULL REFERENCES mot_cle(mot_cle_id) ON DELETE CASCADE,
    PRIMARY KEY (document_id, mot_cle_id)
);

-- Journal d'audit : alimenté automatiquement par des déclencheurs (voir 02_triggers.sql)
CREATE TABLE historique (
    historique_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id   BIGINT       NOT NULL,          -- pas de clé étrangère : la trace survit à la suppression
    agent_id      INTEGER      REFERENCES agent(agent_id),
    action        action_histo NOT NULL,
    horodatage    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    detail        TEXT
);

-- ---------------------------------------------------------------------
-- Index : accélèrent les recherches et les jointures les plus fréquentes
-- ---------------------------------------------------------------------
CREATE INDEX idx_dossier_usager   ON dossier (usager_id);
CREATE INDEX idx_dossier_service  ON dossier (service_id, statut);
CREATE INDEX idx_document_dossier ON document (dossier_id);
CREATE INDEX idx_document_type    ON document (type_id);
CREATE INDEX idx_document_date    ON document (date_depot);
CREATE INDEX idx_historique_doc   ON historique (document_id, horodatage);
CREATE UNIQUE INDEX uq_document_empreinte ON document (dossier_id, empreinte) WHERE empreinte IS NOT NULL;
-- Recherche plein texte sur les titres (en français)
CREATE INDEX idx_document_titre_fts ON document USING gin (to_tsvector('french', titre));
