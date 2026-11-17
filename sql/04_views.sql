-- =====================================================================
-- 04 — Vues métier (réutilisables par un outil de reporting, ex. Power BI)
-- =====================================================================
SET search_path TO ged;

-- Synthèse de chaque dossier : usager, service, nombre de pièces, pièces manquantes, délai
CREATE OR REPLACE VIEW v_dossier_synthese AS
SELECT d.dossier_id,
       d.numero,
       s.libelle                                   AS service,
       u.reference                                 AS usager,
       d.objet,
       d.statut,
       d.date_ouverture,
       d.date_cloture,
       COALESCE(d.date_cloture, CURRENT_DATE) - d.date_ouverture AS anciennete_jours,
       count(doc.document_id)                      AS nb_documents,
       (SELECT count(*) FROM pieces_manquantes(d.dossier_id)) AS nb_pieces_manquantes
FROM dossier d
JOIN service s USING (service_id)
JOIN usager  u USING (usager_id)
LEFT JOIN document doc USING (dossier_id)
GROUP BY d.dossier_id, s.libelle, u.reference;

-- Dossiers non clos ouverts depuis plus de 30 jours
CREATE OR REPLACE VIEW v_dossiers_en_retard AS
SELECT *
FROM v_dossier_synthese
WHERE statut <> 'clos' AND anciennete_jours > 30
ORDER BY anciennete_jours DESC;

-- Documents dont la durée de conservation est dépassée (à détruire ou à verser aux archives)
CREATE OR REPLACE VIEW v_documents_echus AS
SELECT doc.document_id,
       doc.titre,
       td.libelle AS type_document,
       td.duree_conservation_ans,
       doc.date_depot::date AS date_depot,
       (doc.date_depot + make_interval(years => td.duree_conservation_ans))::date AS date_fin_conservation
FROM document doc
JOIN type_document td USING (type_id)
JOIN dossier d USING (dossier_id)
WHERE d.statut = 'clos'
  AND doc.date_depot + make_interval(years => td.duree_conservation_ans) < CURRENT_DATE;

-- Tableau de bord par service
CREATE OR REPLACE VIEW v_tableau_bord_service AS
-- (agrégats calculés séparément pour ne pas pondérer les délais par le nombre de documents)
WITH dos AS (
    SELECT service_id,
           count(*)                                         AS dossiers,
           count(*) FILTER (WHERE statut <> 'clos')         AS dossiers_actifs,
           round(avg(date_cloture - date_ouverture), 1)     AS delai_moyen_jours
    FROM dossier
    GROUP BY service_id
), docs AS (
    SELECT d.service_id,
           count(*)                                 AS documents,
           round(sum(doc.taille_ko) / 1024.0, 1)    AS volume_mo
    FROM document doc
    JOIN dossier d USING (dossier_id)
    GROUP BY d.service_id
)
SELECT s.libelle AS service,
       COALESCE(dos.dossiers, 0)        AS dossiers,
       COALESCE(dos.dossiers_actifs, 0) AS dossiers_actifs,
       COALESCE(docs.documents, 0)      AS documents,
       COALESCE(docs.volume_mo, 0)      AS volume_mo,
       dos.delai_moyen_jours
FROM service s
LEFT JOIN dos  USING (service_id)
LEFT JOIN docs USING (service_id)
ORDER BY dossiers DESC;
