-- =====================================================================
-- 03 — Jeu de données FICTIF (généré, reproductible)
-- Aucune donnée réelle : noms, dossiers et documents sont inventés.
-- =====================================================================
SET search_path TO ged;
SELECT setseed(0.42);  -- même jeu de données à chaque exécution

-- Les déclencheurs sont désactivés pendant le chargement initial :
-- l'historique est généré plus bas avec des dates réalistes.
SET session_replication_role = replica;

-- ---------------------------------------------------------------------
-- Référentiels
-- ---------------------------------------------------------------------
INSERT INTO service (code, libelle) VALUES
    ('ETC', 'État civil'),
    ('PAS', 'Passeports et titres'),
    ('VIS', 'Visas'),
    ('SOC', 'Affaires sociales'),
    ('ADM', 'Administration générale'),
    ('COM', 'Communication');

-- Durées de conservation données à titre d'illustration
INSERT INTO type_document (libelle, duree_conservation_ans, confidentialite) VALUES
    ('Formulaire de demande',    10, 'interne'),
    ('Pièce d''identité',        10, 'confidentiel'),
    ('Acte de naissance',        50, 'confidentiel'),
    ('Photo d''identité',         5, 'confidentiel'),
    ('Justificatif de domicile',  5, 'interne'),
    ('Courrier entrant',          5, 'interne'),
    ('Courrier sortant',          5, 'interne'),
    ('Attestation',              10, 'interne'),
    ('Note interne',              2, 'interne'),
    ('Rapport d''activité',      10, 'public');

INSERT INTO piece_obligatoire (service_id, type_id)
SELECT s.service_id, t.type_id
FROM service s
JOIN type_document t ON (s.code, t.libelle) IN (
    ('ETC', 'Formulaire de demande'), ('ETC', 'Pièce d''identité'), ('ETC', 'Acte de naissance'),
    ('PAS', 'Formulaire de demande'), ('PAS', 'Pièce d''identité'), ('PAS', 'Photo d''identité'), ('PAS', 'Justificatif de domicile'),
    ('VIS', 'Formulaire de demande'), ('VIS', 'Pièce d''identité'), ('VIS', 'Photo d''identité'),
    ('SOC', 'Formulaire de demande'), ('SOC', 'Justificatif de domicile')
);

INSERT INTO mot_cle (libelle) VALUES
    ('urgent'), ('renouvellement'), ('première demande'), ('rectification'), ('mineur'),
    ('transcription'), ('réclamation'), ('à compléter'), ('numérisé'), ('original reçu'), ('famille'), ('étudiant');

-- ---------------------------------------------------------------------
-- Agents (24) et usagers (500)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE noms AS
SELECT ARRAY['Martin','Bernard','Diallo','Dubois','Ndiaye','Thomas','Robert','Diop','Petit','Durand','Sow','Leroy',
             'Moreau','Fall','Simon','Laurent','Ba','Lefebvre','Michel','Garcia','Faye','David','Bertrand','Gueye',
             'Roux','Vincent','Fournier','Mbaye','Morel','Girard','Kane','Bonnet','Dupont','Cissé','Lambert','Fontaine'] AS nom,
       ARRAY['Aminata','Lucas','Fatou','Hugo','Moussa','Léa','Awa','Louis','Chloé','Ibrahima','Emma','Mariama',
             'Gabriel','Khady','Jules','Inès','Ousmane','Manon','Adama','Camille','Aïssatou','Nathan','Sarah','Mamadou',
             'Clara','Cheikh','Jade','Rokhaya','Arthur','Binta','Paul','Ndeye','Yanis','Coumba','Lina','Abdou'] AS prenom;

INSERT INTO agent (nom, prenom, email, role, service_id)
SELECT n.nom[1 + (g * 7) % 36], n.prenom[1 + (g * 11) % 36],
       'agent' || lpad(g::text, 2, '0') || '@ged.example',
       CASE WHEN g = 1 THEN 'administrateur'::role_agent
            WHEN g <= 7 THEN 'responsable'::role_agent
            ELSE 'agent'::role_agent END,
       1 + (g - 1) % 6
FROM generate_series(1, 24) g, noms n;

INSERT INTO usager (reference, nom, prenom, ville)
SELECT 'USG-' || lpad(g::text, 6, '0'),
       n.nom[1 + floor(random() * 36)::int],
       n.prenom[1 + floor(random() * 36)::int],
       (ARRAY['Paris','Paris','Paris','Nanterre','Montreuil','Saint-Denis','Créteil','Boulogne-Billancourt',
              'Argenteuil','Versailles','Évry','Lyon','Marseille'])[1 + floor(random() * 13)::int]
FROM generate_series(1, 500) g, noms n;

-- ---------------------------------------------------------------------
-- Dossiers (900, de janvier 2024 à novembre 2026)
-- ---------------------------------------------------------------------
INSERT INTO dossier (numero, usager_id, service_id, agent_id, objet, statut, date_ouverture, date_cloture)
WITH base AS (
    SELECT g,
           1 + floor(random() * 500)::int AS usager_id,
           (ARRAY[1,1,1,2,2,2,2,3,3,4,4,5,6])[1 + floor(random() * 13)::int] AS service_id,
           DATE '2024-01-02' + floor(random() * (DATE '2026-11-12' - DATE '2024-01-02'))::int AS d_ouv,
           random() AS r_statut,
           3 + floor(random() * 55)::int AS duree
    FROM generate_series(1, 900) g
), statut AS (
    SELECT b.*,
           DATE '2026-11-16' - d_ouv AS age,
           CASE
               WHEN DATE '2026-11-16' - d_ouv > 180 THEN 'clos'
               WHEN DATE '2026-11-16' - d_ouv > 90 THEN CASE WHEN r_statut < .90 THEN 'clos' ELSE 'en_cours' END
               WHEN DATE '2026-11-16' - d_ouv > 30 THEN CASE WHEN r_statut < .60 THEN 'clos' WHEN r_statut < .90 THEN 'en_cours' ELSE 'ouvert' END
               ELSE CASE WHEN r_statut < .15 THEN 'clos' WHEN r_statut < .60 THEN 'en_cours' ELSE 'ouvert' END
           END::statut_dossier AS statut
    FROM base b
)
SELECT s.code || '-' || extract(year FROM st.d_ouv) || '-' ||
         lpad(row_number() OVER (PARTITION BY st.service_id, extract(year FROM st.d_ouv) ORDER BY st.d_ouv, st.g)::text, 5, '0'),
       st.usager_id, st.service_id,
       (SELECT a.agent_id FROM agent a WHERE a.service_id = st.service_id ORDER BY random() + st.g * 0 LIMIT 1),
       CASE s.code
           WHEN 'ETC' THEN (ARRAY['Transcription d''acte de naissance','Demande de copie d''acte','Déclaration de mariage','Rectification d''état civil'])[1 + floor(random() * 4)::int]
           WHEN 'PAS' THEN (ARRAY['Demande de passeport','Renouvellement de passeport','Demande de carte d''identité','Déclaration de perte'])[1 + floor(random() * 4)::int]
           WHEN 'VIS' THEN (ARRAY['Visa court séjour','Visa long séjour','Visa étudiant'])[1 + floor(random() * 3)::int]
           WHEN 'SOC' THEN (ARRAY['Demande d''aide sociale','Rapatriement','Accompagnement administratif'])[1 + floor(random() * 3)::int]
           WHEN 'ADM' THEN (ARRAY['Gestion des fournitures','Marché public','Suivi budgétaire'])[1 + floor(random() * 3)::int]
           ELSE (ARRAY['Campagne d''information','Relations presse','Publication du site web'])[1 + floor(random() * 3)::int]
       END,
       st.statut,
       st.d_ouv,
       CASE WHEN st.statut = 'clos' THEN LEAST(st.d_ouv + st.duree, DATE '2026-11-16') END
FROM statut st
JOIN service s ON s.service_id = st.service_id;

-- ---------------------------------------------------------------------
-- Documents : pièces obligatoires + pièces complémentaires
-- ---------------------------------------------------------------------
CREATE TEMP TABLE pieces AS
-- Pièces obligatoires : toutes présentes si le dossier est clos, en partie sinon
SELECT d.dossier_id, po.type_id
FROM dossier d
JOIN piece_obligatoire po USING (service_id)
WHERE d.statut = 'clos'
   OR random() < CASE d.statut WHEN 'en_cours' THEN .80 ELSE .45 END
UNION ALL
-- Pièces complémentaires : 0 à 3 par dossier
SELECT d.dossier_id,
       (SELECT type_id FROM type_document
        WHERE libelle IN ('Courrier entrant','Courrier sortant','Attestation','Note interne','Rapport d''activité')
        ORDER BY random() + k * 0 LIMIT 1)
FROM dossier d
CROSS JOIN LATERAL generate_series(1, floor(random() * 4)::int + 0 * d.dossier_id) k;

INSERT INTO document (dossier_id, type_id, titre, nom_fichier, format, taille_ko, empreinte, version, statut, depose_par, date_depot, date_maj)
SELECT x.dossier_id, x.type_id,
       x.libelle || ' – ' || x.usager_nom || ' ' || x.usager_prenom,
       lower(translate(replace(x.libelle, ' ', '_'), 'éèêàçô''', 'eeeaco_')) || '_' || x.numero || '.' || x.format,
       x.format,
       CASE WHEN x.format IN ('jpg','png') THEN 150 + floor(random() * 900)::int
            ELSE 40 + floor(random() * 2500)::int END,
       encode(sha256((x.dossier_id || '-' || x.type_id || '-' || random())::bytea), 'hex'),
       1 + (random() < .15)::int + (random() < .05)::int,
       CASE
           WHEN x.statut = 'clos' AND x.date_cloture < DATE '2025-11-16' THEN 'archive'
           WHEN x.statut = 'clos' THEN 'valide'
           WHEN random() < .6 THEN 'valide'
           ELSE 'brouillon'
       END::statut_document,
       x.agent_id,
       x.depot, x.depot
FROM (
    SELECT p.dossier_id, p.type_id, td.libelle, d.numero, d.statut, d.date_cloture, d.agent_id,
           u.nom AS usager_nom, u.prenom AS usager_prenom,
           CASE WHEN td.libelle = 'Photo d''identité' THEN 'jpg'
                WHEN td.libelle = 'Courrier sortant' AND random() < .4 THEN 'docx'
                WHEN td.libelle = 'Rapport d''activité' THEN 'xlsx'
                ELSE 'pdf' END AS format,
           (d.date_ouverture
             + floor(random() * GREATEST(COALESCE(d.date_cloture, DATE '2026-11-16') - d.date_ouverture, 1))::int
             + time '08:30' + random() * interval '9 hours')::timestamptz AS depot
    FROM pieces p
    JOIN dossier d       USING (dossier_id)
    JOIN usager u        USING (usager_id)
    JOIN type_document td ON td.type_id = p.type_id
) x;

-- Mots-clés : 0 à 3 par document
INSERT INTO document_mot_cle (document_id, mot_cle_id)
SELECT DISTINCT d.document_id, 1 + floor(random() * 12)::int
FROM document d
CROSS JOIN LATERAL generate_series(1, floor(random() * 4)::int + 0 * d.document_id::int) k;

-- ---------------------------------------------------------------------
-- Historique (journal d'audit) avec des dates cohérentes
-- ---------------------------------------------------------------------
INSERT INTO historique (document_id, agent_id, action, horodatage, detail)
SELECT document_id, depose_par, 'creation', date_depot, 'Dépôt de « ' || titre || ' » (v1)'
FROM document;

INSERT INTO historique (document_id, agent_id, action, horodatage, detail)
SELECT d.document_id, d.depose_par, 'modification',
       d.date_depot + v * interval '1 day' + random() * interval '6 hours',
       'Version ' || v || ' → ' || (v + 1)
FROM document d
CROSS JOIN LATERAL generate_series(1, d.version - 1) v;

INSERT INTO historique (document_id, agent_id, action, horodatage, detail)
SELECT d.document_id,
       (SELECT a.agent_id FROM agent a JOIN dossier ds ON ds.service_id = a.service_id
        WHERE ds.dossier_id = d.dossier_id AND a.role <> 'agent' ORDER BY random() + d.document_id * 0 LIMIT 1),
       'validation',
       d.date_depot + interval '3 days' + random() * interval '48 hours',
       'Statut : brouillon → valide'
FROM document d
WHERE d.statut IN ('valide', 'archive');

INSERT INTO historique (document_id, agent_id, action, horodatage, detail)
SELECT d.document_id, NULL, 'archivage',
       ds.date_cloture + interval '365 days' + random() * interval '20 days',
       'Statut : valide → archive (archivage automatique)'
FROM document d JOIN dossier ds USING (dossier_id)
WHERE d.statut = 'archive';

INSERT INTO historique (document_id, agent_id, action, horodatage, detail)
SELECT d.document_id,
       (SELECT a.agent_id FROM agent a JOIN dossier ds ON ds.service_id = a.service_id
        WHERE ds.dossier_id = d.dossier_id ORDER BY random() + k * 0 LIMIT 1),
       'consultation',
       d.date_depot + random() * (TIMESTAMPTZ '2026-11-16 18:00' - d.date_depot),
       NULL
FROM document d
CROSS JOIN LATERAL generate_series(1, floor(random() * 5)::int + 0 * d.document_id::int) k;

-- Date de dernière mise à jour = dernier événement d'écriture
UPDATE document d SET date_maj = h.derniere
FROM (SELECT document_id, max(horodatage) AS derniere FROM historique
      WHERE action <> 'consultation' GROUP BY document_id) h
WHERE h.document_id = d.document_id;

SET session_replication_role = origin;

DROP TABLE noms;
DROP TABLE pieces;

ANALYZE;
