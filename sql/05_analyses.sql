-- =====================================================================
-- 05 — Requêtes d'analyse : pilotage de l'activité et qualité des données
-- =====================================================================
SET search_path TO ged;
\pset footer off

\echo '\n== Q1. Documents déposés par mois, avec cumul (fonction de fenêtre SUM OVER)'
SELECT to_char(date_trunc('month', date_depot), 'YYYY-MM')          AS mois,
       count(*)                                                     AS documents,
       sum(count(*)) OVER (ORDER BY date_trunc('month', date_depot)) AS cumul
FROM document
WHERE date_depot >= DATE '2026-01-01'
GROUP BY date_trunc('month', date_depot)
ORDER BY 1;

\echo '\n== Q2. Délai de traitement des dossiers clos par service (moyenne, médiane, 90e centile)'
SELECT s.libelle                                                         AS service,
       count(*)                                                          AS dossiers_clos,
       round(avg(d.date_cloture - d.date_ouverture), 1)                  AS moyenne_j,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY d.date_cloture - d.date_ouverture)::numeric, 1) AS mediane_j,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY d.date_cloture - d.date_ouverture)::numeric, 1) AS p90_j
FROM dossier d
JOIN service s USING (service_id)
WHERE d.statut = 'clos'
GROUP BY s.libelle
ORDER BY moyenne_j DESC;

\echo '\n== Q3. Complétude des dossiers en cours : combien de pièces obligatoires manquent ?'
SELECT service,
       count(*)                                              AS dossiers_actifs,
       count(*) FILTER (WHERE nb_pieces_manquantes = 0)      AS complets,
       round(100.0 * count(*) FILTER (WHERE nb_pieces_manquantes = 0) / count(*), 1) AS taux_completude_pct
FROM v_dossier_synthese
WHERE statut <> 'clos'
GROUP BY service
ORDER BY taux_completude_pct;

\echo '\n== Q4. Pièces manquantes les plus fréquentes'
SELECT pm.libelle AS piece_manquante, count(*) AS dossiers_concernes
FROM dossier d
CROSS JOIN LATERAL pieces_manquantes(d.dossier_id) pm
WHERE d.statut <> 'clos'
GROUP BY pm.libelle
ORDER BY dossiers_concernes DESC;

\echo '\n== Q5. Les 2 agents les plus actifs de chaque service (RANK OVER PARTITION BY)'
WITH activite AS (
    SELECT s.libelle AS service, a.prenom || ' ' || a.nom AS agent, count(*) AS actions,
           rank() OVER (PARTITION BY s.libelle ORDER BY count(*) DESC) AS rang
    FROM historique h
    JOIN agent a   USING (agent_id)
    JOIN service s USING (service_id)
    WHERE h.action IN ('creation', 'validation', 'modification')
    GROUP BY s.libelle, a.agent_id
)
SELECT service, rang, agent, actions FROM activite WHERE rang <= 2 ORDER BY service, rang;

\echo '\n== Q6. Formats de fichiers et volume de stockage (part du total)'
SELECT format,
       count(*)                                                   AS documents,
       round(sum(taille_ko) / 1024.0, 1)                          AS volume_mo,
       round(100.0 * sum(taille_ko) / sum(sum(taille_ko)) OVER (), 1) AS part_volume_pct
FROM document
GROUP BY format
ORDER BY volume_mo DESC;

\echo '\n== Q7. Traçabilité : documents confidentiels les plus consultés'
SELECT doc.document_id, td.libelle AS type, count(*) AS consultations,
       count(DISTINCT h.agent_id) AS agents_distincts,
       max(h.horodatage)::date    AS derniere_consultation
FROM historique h
JOIN document doc     USING (document_id)
JOIN type_document td USING (type_id)
WHERE h.action = 'consultation' AND td.confidentialite = 'confidentiel'
GROUP BY doc.document_id, td.libelle
ORDER BY consultations DESC, doc.document_id
LIMIT 5;

\echo '\n== Q8. Qualité des données : contrôles automatiques'
SELECT 'Documents sans mot-clé' AS controle,
       count(*) AS anomalies
FROM document doc
WHERE NOT EXISTS (SELECT 1 FROM document_mot_cle m WHERE m.document_id = doc.document_id)
UNION ALL
SELECT 'Brouillons de plus de 30 jours', count(*)
FROM document WHERE statut = 'brouillon' AND date_depot < now() - interval '30 days'
UNION ALL
SELECT 'Fichiers en double (même empreinte SHA-256)', count(*) - count(DISTINCT empreinte)
FROM document WHERE empreinte IS NOT NULL
UNION ALL
SELECT 'Dossiers clos avec pièces manquantes', count(*)
FROM v_dossier_synthese WHERE statut = 'clos' AND nb_pieces_manquantes > 0;

\echo '\n== Q9. Évolution trimestrielle du délai moyen de traitement (LAG)'
WITH trimestres AS (
    SELECT to_char(date_trunc('quarter', date_cloture), 'YYYY-"T"Q') AS trimestre,
           round(avg(date_cloture - date_ouverture), 1)              AS delai_moyen_j
    FROM dossier
    WHERE statut = 'clos'
    GROUP BY date_trunc('quarter', date_cloture)
)
SELECT trimestre, delai_moyen_j,
       delai_moyen_j - lag(delai_moyen_j) OVER (ORDER BY trimestre) AS variation_j
FROM trimestres
ORDER BY trimestre;

\echo '\n== Q10. Recherche plein texte (index GIN) : « acte naissance »'
SELECT document_id, titre
FROM document
WHERE to_tsvector('french', titre) @@ plainto_tsquery('french', 'acte naissance')
ORDER BY document_id
LIMIT 5;

\echo '\n== Q11. Durée de conservation dépassée : documents à détruire ou à verser aux archives'
SELECT type_document, count(*) AS documents, min(date_fin_conservation) AS plus_ancienne_echeance
FROM v_documents_echus
GROUP BY type_document;
