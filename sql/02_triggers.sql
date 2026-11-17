-- =====================================================================
-- 02 — Traçabilité : déclencheurs (triggers) et fonctions PL/pgSQL
-- =====================================================================
SET search_path TO ged;

-- L'application indique l'agent connecté avec :  SET ged.agent_id = '12';
CREATE OR REPLACE FUNCTION agent_courant() RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('ged.agent_id', true), '')::INTEGER
$$;

-- Journalise automatiquement chaque création, modification, validation,
-- archivage ou suppression de document.
CREATE OR REPLACE FUNCTION journaliser_document() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_action action_histo;
    v_detail TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO historique (document_id, agent_id, action, horodatage, detail)
        VALUES (NEW.document_id, COALESCE(agent_courant(), NEW.depose_par), 'creation', NEW.date_depot,
                format('Dépôt de « %s » (v%s)', NEW.titre, NEW.version));
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.statut IS DISTINCT FROM OLD.statut THEN
            v_action := CASE NEW.statut WHEN 'valide' THEN 'validation'
                                        WHEN 'archive' THEN 'archivage'
                                        ELSE 'modification' END;
            v_detail := format('Statut : %s → %s', OLD.statut, NEW.statut);
        ELSE
            v_action := 'modification';
            v_detail := format('Version %s → %s', OLD.version, NEW.version);
        END IF;
        NEW.date_maj := now();
        INSERT INTO historique (document_id, agent_id, action, detail)
        VALUES (NEW.document_id, agent_courant(), v_action, v_detail);
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO historique (document_id, agent_id, action, detail)
        VALUES (OLD.document_id, agent_courant(), 'suppression', format('Suppression de « %s »', OLD.titre));
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER trg_document_insert AFTER INSERT ON document
    FOR EACH ROW EXECUTE FUNCTION journaliser_document();
CREATE TRIGGER trg_document_update BEFORE UPDATE ON document
    FOR EACH ROW WHEN (OLD.* IS DISTINCT FROM NEW.*) EXECUTE FUNCTION journaliser_document();
CREATE TRIGGER trg_document_delete AFTER DELETE ON document
    FOR EACH ROW EXECUTE FUNCTION journaliser_document();

-- Règle métier : un document archivé ne peut plus être modifié (seulement consulté).
CREATE OR REPLACE FUNCTION interdire_modif_archive() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.statut = 'archive' THEN
        RAISE EXCEPTION 'Le document % est archivé : modification interdite', OLD.document_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_document_archive BEFORE UPDATE ON document
    FOR EACH ROW EXECUTE FUNCTION interdire_modif_archive();

-- Règle métier : un dossier ne peut être clos que si toutes les pièces
-- obligatoires de son service sont présentes et validées.
CREATE OR REPLACE FUNCTION pieces_manquantes(p_dossier_id INTEGER)
RETURNS TABLE (type_id SMALLINT, libelle VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT po.type_id, td.libelle
    FROM dossier d
    JOIN piece_obligatoire po ON po.service_id = d.service_id
    JOIN type_document td     ON td.type_id = po.type_id
    WHERE d.dossier_id = p_dossier_id
      AND NOT EXISTS (
          SELECT 1 FROM document doc
          WHERE doc.dossier_id = d.dossier_id
            AND doc.type_id = po.type_id
            AND doc.statut IN ('valide', 'archive')
      )
$$;

CREATE OR REPLACE FUNCTION controler_cloture() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_manquantes TEXT;
BEGIN
    IF NEW.statut = 'clos' AND OLD.statut IS DISTINCT FROM 'clos' THEN
        SELECT string_agg(libelle, ', ') INTO v_manquantes FROM pieces_manquantes(NEW.dossier_id);
        IF v_manquantes IS NOT NULL THEN
            RAISE EXCEPTION 'Dossier % : clôture impossible, pièces manquantes : %', NEW.numero, v_manquantes
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_dossier_cloture BEFORE UPDATE OF statut ON dossier
    FOR EACH ROW EXECUTE FUNCTION controler_cloture();
