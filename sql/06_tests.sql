-- =====================================================================
-- 06 — Tests automatiques des règles métier
-- Tout est exécuté dans une transaction annulée à la fin : la base n'est pas modifiée.
-- Un test qui échoue lève une exception et arrête le script.
-- =====================================================================
SET search_path TO ged;
BEGIN;
SET LOCAL ged.agent_id = '2';

-- Test 1 : un format de fichier non autorisé est refusé
DO $$
BEGIN
    BEGIN
        INSERT INTO document (dossier_id, type_id, titre, nom_fichier, format, taille_ko, depose_par)
        VALUES (1, 1, 'Test', 'test.exe', 'exe', 10, 1);
        RAISE EXCEPTION 'ÉCHEC test 1 : le format .exe a été accepté';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK  test 1 : format non autorisé refusé';
    END;
END $$;

-- Test 2 : un dossier clos doit avoir une date de clôture
DO $$
BEGIN
    BEGIN
        INSERT INTO dossier (numero, usager_id, service_id, objet, statut)
        VALUES ('TEST-0001', 1, 1, 'Test', 'clos');
        RAISE EXCEPTION 'ÉCHEC test 2 : dossier clos sans date de clôture accepté';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK  test 2 : dossier clos sans date de clôture refusé';
    END;
END $$;

-- Test 3 : le dépôt d'un document est journalisé automatiquement
DO $$
DECLARE v_id BIGINT; v_nb INT;
BEGIN
    INSERT INTO document (dossier_id, type_id, titre, nom_fichier, format, taille_ko, depose_par)
    VALUES (1, 6, 'Courrier de test', 'courrier_test.pdf', 'pdf', 120, 2)
    RETURNING document_id INTO v_id;
    SELECT count(*) INTO v_nb FROM historique WHERE document_id = v_id AND action = 'creation';
    IF v_nb <> 1 THEN RAISE EXCEPTION 'ÉCHEC test 3 : création non journalisée'; END IF;
    RAISE NOTICE 'OK  test 3 : création journalisée dans l''historique';

    -- Test 4 : la validation est journalisée avec l'agent connecté
    UPDATE document SET statut = 'valide' WHERE document_id = v_id;
    SELECT count(*) INTO v_nb FROM historique
    WHERE document_id = v_id AND action = 'validation' AND agent_id = 2;
    IF v_nb <> 1 THEN RAISE EXCEPTION 'ÉCHEC test 4 : validation non journalisée'; END IF;
    RAISE NOTICE 'OK  test 4 : validation journalisée avec l''agent connecté';

    -- Test 5 : un document archivé ne peut plus être modifié
    UPDATE document SET statut = 'archive' WHERE document_id = v_id;
    BEGIN
        UPDATE document SET titre = 'Titre modifié' WHERE document_id = v_id;
        RAISE EXCEPTION 'ÉCHEC test 5 : document archivé modifié';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK  test 5 : modification d''un document archivé refusée';
    END;

    -- Test 6 : la suppression laisse une trace dans l'historique
    DELETE FROM document WHERE document_id = v_id;
    SELECT count(*) INTO v_nb FROM historique WHERE document_id = v_id AND action = 'suppression';
    IF v_nb <> 1 THEN RAISE EXCEPTION 'ÉCHEC test 6 : suppression non tracée'; END IF;
    RAISE NOTICE 'OK  test 6 : suppression tracée (la trace survit au document)';
END $$;

-- Test 7 : impossible de clore un dossier auquel il manque des pièces obligatoires
DO $$
DECLARE v_dossier INT;
BEGIN
    SELECT dossier_id INTO v_dossier FROM v_dossier_synthese
    WHERE statut <> 'clos' AND nb_pieces_manquantes > 0 LIMIT 1;
    IF v_dossier IS NULL THEN RAISE EXCEPTION 'ÉCHEC test 7 : aucun dossier incomplet pour tester'; END IF;
    BEGIN
        UPDATE dossier SET statut = 'clos', date_cloture = CURRENT_DATE WHERE dossier_id = v_dossier;
        RAISE EXCEPTION 'ÉCHEC test 7 : dossier incomplet clos';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK  test 7 : clôture d''un dossier incomplet refusée';
    END;
END $$;

-- Test 8 : un dossier complet peut être clos
DO $$
DECLARE v_dossier INT;
BEGIN
    SELECT dossier_id INTO v_dossier FROM v_dossier_synthese
    WHERE statut <> 'clos' AND nb_pieces_manquantes = 0 LIMIT 1;
    IF v_dossier IS NULL THEN RAISE EXCEPTION 'ÉCHEC test 8 : aucun dossier complet pour tester'; END IF;
    UPDATE dossier SET statut = 'clos', date_cloture = CURRENT_DATE WHERE dossier_id = v_dossier;
    RAISE NOTICE 'OK  test 8 : clôture d''un dossier complet acceptée';
END $$;

ROLLBACK;
\echo '\nTous les tests sont passés.'
