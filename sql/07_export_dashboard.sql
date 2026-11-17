-- =====================================================================
-- 07 — Export JSON pour le tableau de bord web (docs/index.html)
-- Usage : psql -At -d ged_demo -f sql/07_export_dashboard.sql > docs/data/dashboard.json
-- =====================================================================
SET search_path TO ged;

SELECT json_build_object(
    'genere_le', to_char(now(), 'YYYY-MM-DD'),

    'kpis', (SELECT json_build_object(
        'dossiers',        (SELECT count(*) FROM dossier),
        'dossiers_actifs', (SELECT count(*) FROM dossier WHERE statut <> 'clos'),
        'documents',       (SELECT count(*) FROM document),
        'volume_go',       (SELECT round(sum(taille_ko) / 1024.0 / 1024.0, 2) FROM document),
        'delai_median',    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY date_cloture - date_ouverture) FROM dossier WHERE statut = 'clos'),
        'completude_pct',  (SELECT round(100.0 * count(*) FILTER (WHERE nb_pieces_manquantes = 0) / count(*), 1) FROM v_dossier_synthese WHERE statut <> 'clos'),
        'evenements',      (SELECT count(*) FROM historique),
        'agents',          (SELECT count(*) FROM agent),
        'usagers',         (SELECT count(*) FROM usager)
    )),

    'services', (SELECT json_agg(x ORDER BY x.dossiers DESC) FROM (
        SELECT t.service, t.dossiers, t.dossiers_actifs, t.documents, t.volume_mo, t.delai_moyen_jours,
               (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY d.date_cloture - d.date_ouverture)::numeric, 1)
                  FROM dossier d JOIN service s USING (service_id) WHERE s.libelle = t.service AND d.statut = 'clos') AS delai_median,
               (SELECT round(percentile_cont(0.9) WITHIN GROUP (ORDER BY d.date_cloture - d.date_ouverture)::numeric, 1)
                  FROM dossier d JOIN service s USING (service_id) WHERE s.libelle = t.service AND d.statut = 'clos') AS delai_p90,
               (SELECT round(100.0 * count(*) FILTER (WHERE nb_pieces_manquantes = 0) / NULLIF(count(*), 0), 1)
                  FROM v_dossier_synthese v WHERE v.service = t.service AND v.statut <> 'clos') AS completude_pct,
               (SELECT count(*) FROM piece_obligatoire po JOIN service s USING (service_id) WHERE s.libelle = t.service) AS pieces_exigees
        FROM v_tableau_bord_service t
    ) x),

    'mensuel', (SELECT json_agg(x ORDER BY x.mois) FROM (
        SELECT to_char(m, 'YYYY-MM') AS mois,
               (SELECT count(*) FROM dossier WHERE date_trunc('month', date_ouverture) = m) AS ouverts,
               (SELECT count(*) FROM dossier WHERE date_trunc('month', date_cloture) = m)   AS clos,
               (SELECT count(*) FROM document WHERE date_trunc('month', date_depot) = m)     AS documents
        FROM generate_series(DATE '2024-01-01', date_trunc('month', CURRENT_DATE), interval '1 month') m
    ) x),

    'trimestres', (SELECT json_agg(x ORDER BY x.trimestre) FROM (
        SELECT to_char(date_trunc('quarter', date_cloture), 'YYYY-"T"Q') AS trimestre,
               round(avg(date_cloture - date_ouverture), 1) AS delai_moyen
        FROM dossier WHERE statut = 'clos' GROUP BY date_trunc('quarter', date_cloture)
    ) x),

    'statuts_documents', (SELECT json_object_agg(statut, n) FROM (SELECT statut, count(*) n FROM document GROUP BY statut) x),
    'statuts_dossiers',  (SELECT json_object_agg(statut, n) FROM (SELECT statut, count(*) n FROM dossier GROUP BY statut) x),

    'formats', (SELECT json_agg(x ORDER BY x.volume_mo DESC) FROM (
        SELECT format, count(*) AS documents, round(sum(taille_ko) / 1024.0, 1) AS volume_mo FROM document GROUP BY format
    ) x),

    'confidentialite', (SELECT json_agg(x ORDER BY x.documents DESC) FROM (
        SELECT td.confidentialite AS niveau, count(*) AS documents FROM document JOIN type_document td USING (type_id) GROUP BY 1
    ) x),

    'pieces_manquantes', (SELECT json_agg(x ORDER BY x.dossiers DESC) FROM (
        SELECT pm.libelle AS piece, count(*) AS dossiers
        FROM dossier d CROSS JOIN LATERAL pieces_manquantes(d.dossier_id) pm
        WHERE d.statut <> 'clos' GROUP BY pm.libelle
    ) x),

    'actions', (SELECT json_agg(x ORDER BY x.n DESC) FROM (
        SELECT action, count(*) AS n FROM historique GROUP BY action
    ) x),

    'qualite', json_build_array(
        json_build_object('controle', 'Dossiers clos avec pièces manquantes',
                          'anomalies', (SELECT count(*) FROM v_dossier_synthese WHERE statut = 'clos' AND nb_pieces_manquantes > 0)),
        json_build_object('controle', 'Fichiers en double (même empreinte SHA-256)',
                          'anomalies', (SELECT count(*) - count(DISTINCT empreinte) FROM document WHERE empreinte IS NOT NULL)),
        json_build_object('controle', 'Brouillons de plus de 30 jours',
                          'anomalies', (SELECT count(*) FROM document WHERE statut = 'brouillon' AND date_depot < now() - interval '30 days')),
        json_build_object('controle', 'Documents sans mot-clé',
                          'anomalies', (SELECT count(*) FROM document doc WHERE NOT EXISTS (SELECT 1 FROM document_mot_cle m WHERE m.document_id = doc.document_id))),
        json_build_object('controle', 'Documents à durée de conservation dépassée',
                          'anomalies', (SELECT count(*) FROM v_documents_echus))
    ),

    'retard', (SELECT json_agg(x) FROM (
        SELECT numero, service, objet, anciennete_jours, nb_pieces_manquantes
        FROM v_dossiers_en_retard ORDER BY anciennete_jours DESC LIMIT 8
    ) x)
);
