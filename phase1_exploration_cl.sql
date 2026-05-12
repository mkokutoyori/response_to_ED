--==============================================================================
--  PHASE 1 - EXPLORATION FONCTIONNELLE & TECHNIQUE DU MODULE CL (FLEXCUBE)
--  Provisions / cycle de vie credits - perimetre RESTREINT a 7 tables :
--      1) actb_history              (ecritures comptables)
--      2) sttb_account              (compte / GL avec libelle)
--      3) cstb_amount_tag           (libelle des tags par module)
--      4) sttm_trn_code             (libelle des codes transaction)
--      5) cltm_product              (produits CL)
--      6) cltb_account_apps_master  (contrats credit)
--      7) cltb_account_schedules    (echeanciers)
--      8) cltb_account_ude_values   (UDE = taux et parametres)
--
--  Mode d'execution :
--      SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
--      SET LINESIZE 400
--      ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-YYYY';
--      @phase1_exploration_cl.sql
--
--  Sortie : DBMS_OUTPUT structure par sections (A..J).
--  Principes :
--    - Une seule unite anonyme DECLARE/BEGIN/END
--    - Chaque sous-bloc protege par EXCEPTION (on continue meme si une colonne
--      n'existe pas dans la version FLEXCUBE installee)
--    - Echantillon de 8 a 10 dossiers couvrant differents profils
--    - Pour chaque dossier : contrat / produit / UDE / schedule / ecritures
--    - Vues agregees : tags, trn_codes, GL impactes, mapping tag->GL
--
--  Note : la notion d'evenement, de statut, de provision et de write-off n'est
--  ici accessible qu'indirectement, via les colonnes de actb_history :
--    * related_account = reference contrat CL
--    * amount_tag      = nature comptable (PRINCIPAL, INT_ACCR, PENAL, PROV,
--                                          PRVN, WRIT, WROF, DSBR, LIQD ...)
--    * trn_code        = code transaction (lie a sttm_trn_code)
--    * drcr_ind        = sens 'D' debit / 'C' credit
--  La table cltb_account_apps_master donne le statut courant (account_status)
--  et cltb_account_schedules permet de calculer un DPD pour identifier
--  les credits en souffrance.
--==============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 400
SET PAGESIZE 0
SET FEEDBACK OFF
SET VERIFY OFF
ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-YYYY';
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

DECLARE
    --------------------------------------------------------------------------
    -- Types et constantes
    --------------------------------------------------------------------------
    TYPE t_acc_list IS TABLE OF VARCHAR2(35) INDEX BY PLS_INTEGER;
    v_sample        t_acc_list;
    v_label         t_acc_list;
    v_idx           PLS_INTEGER;
    v_acc           VARCHAR2(35);
    v_sep           CONSTANT VARCHAR2(120) := RPAD('=',120,'=');
    v_sub           CONSTANT VARCHAR2(120) := RPAD('-',120,'-');

    --------------------------------------------------------------------------
    -- Helpers
    --------------------------------------------------------------------------
    PROCEDURE p(p_text IN VARCHAR2) IS
    BEGIN
        IF p_text IS NULL THEN
            DBMS_OUTPUT.PUT_LINE(' ');
        ELSE
            FOR i IN 0 .. CEIL(LENGTH(p_text)/250)-1 LOOP
                DBMS_OUTPUT.PUT_LINE( SUBSTR(p_text, i*250+1, 250) );
            END LOOP;
        END IF;
    END;

    PROCEDURE section(p_code VARCHAR2, p_title VARCHAR2) IS
    BEGIN
        p(' ');
        p(v_sep);
        p('SECTION ' || p_code || ' : ' || p_title);
        p(v_sep);
    END;

    PROCEDURE subsection(p_title VARCHAR2) IS
    BEGIN
        p(' ');
        p(v_sub);
        p('>> ' || p_title);
        p(v_sub);
    END;

    FUNCTION row_count(p_table VARCHAR2, p_where VARCHAR2 DEFAULT NULL)
        RETURN VARCHAR2
    IS
        v_sql VARCHAR2(2000);
        v_n   NUMBER;
    BEGIN
        v_sql := 'SELECT COUNT(*) FROM ' || p_table
              || CASE WHEN p_where IS NOT NULL THEN ' WHERE ' || p_where END;
        EXECUTE IMMEDIATE v_sql INTO v_n;
        RETURN TO_CHAR(v_n);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN '[indisponible: ' || SQLCODE || ']';
    END;

    -- Ajoute un compte a l'echantillon s'il n'y est pas deja
    PROCEDURE add_sample(p_acc VARCHAR2, p_lbl VARCHAR2) IS
        v_found BOOLEAN := FALSE;
    BEGIN
        IF p_acc IS NULL THEN RETURN; END IF;
        FOR i IN 1..v_idx LOOP
            IF v_sample(i) = p_acc THEN v_found := TRUE; EXIT; END IF;
        END LOOP;
        IF NOT v_found AND v_idx < 10 THEN
            v_idx := v_idx + 1;
            v_sample(v_idx) := p_acc;
            v_label(v_idx)  := p_lbl;
        END IF;
    END;

BEGIN
    p(v_sep);
    p('EXPLORATION FLEXCUBE - MODULE CL - PHASE 1 (perimetre restreint 8 tables)');
    p('Date execution : ' || TO_CHAR(SYSDATE,'DD-MON-YYYY HH24:MI:SS'));
    p('Schema courant : ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
    p(v_sep);

    --==========================================================================
    -- SECTION A : VOLUMETRIE DES TABLES DU PERIMETRE
    --==========================================================================
    -- Permet de verifier la disponibilite des tables et de calibrer le
    -- perimetre. Si une table est marquee [indisponible], les sections qui
    -- en dependent seront passees mais le script continuera.
    --==========================================================================
    section('A','VOLUMETRIE DES 8 TABLES DU PERIMETRE');

    p( RPAD('cltb_account_apps_master',32) || ' : ' || row_count('cltb_account_apps_master') );
    p( RPAD('cltb_account_schedules',32)   || ' : ' || row_count('cltb_account_schedules') );
    p( RPAD('cltb_account_ude_values',32)  || ' : ' || row_count('cltb_account_ude_values') );
    p( RPAD('cltm_product',32)             || ' : ' || row_count('cltm_product') );
    p( RPAD('actb_history (module=CL)',32) || ' : ' || row_count('actb_history','module=''CL''') );
    p( RPAD('cstb_amount_tag (module=CL)',32) || ' : ' || row_count('cstb_amount_tag','module=''CL''') );
    p( RPAD('sttm_trn_code',32)            || ' : ' || row_count('sttm_trn_code') );
    p( RPAD('sttb_account',32)             || ' : ' || row_count('sttb_account') );

    --==========================================================================
    -- SECTION B : SELECTION DE 8 A 10 DOSSIERS REPRESENTATIFS
    --==========================================================================
    -- Profils recherches (heuristiques sur les seules tables du perimetre) :
    --   1) Commercial      product_category LIKE '%COMM%'
    --   2) Immobilier      product_category LIKE '%MORT%' / '%IMMO%' / '%HOUS%' / '%HOME%'
    --   3) Corporate       product_category LIKE '%CORP%' / '%ENTR%'
    --   4) Particulier     product_category LIKE '%RETAIL%' / '%PART%' / '%INDI%' / '%PERSO%'
    --   5) Restructure     NVL(reschedule_count,0) > 0 (best-effort si colonne dispo)
    --   6) En souffrance   schedule en retard > 30 j et non solde
    --   7) Solde / liquide account_status IN ('L','C')
    --   8) Avec penalites  presence d'ecritures actb tag LIKE '%PENAL%'
    --   9) Avec provisions presence d'ecritures actb tag LIKE '%PROV%' / '%PRVN%'
    --  10) Avec write-off  presence d'ecritures actb tag LIKE '%WRIT%' / '%WROF%'
    -- Si certains profils manquent, on complete par les plus gros encours.
    --==========================================================================
    section('B','CONSTITUTION DE L ECHANTILLON DE DOSSIERS (8 a 10)');

    v_idx := 0;

    -- 1) commercial
    BEGIN
        SELECT account_number INTO v_acc FROM (
            SELECT account_number FROM cltb_account_apps_master
             WHERE UPPER(product_category) LIKE '%COMM%'
               AND account_status NOT IN ('L','C')
             ORDER BY book_date DESC NULLS LAST
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'Commercial');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 2) immobilier
    BEGIN
        SELECT account_number INTO v_acc FROM (
            SELECT account_number FROM cltb_account_apps_master
             WHERE UPPER(product_category) LIKE '%MORT%'
                OR UPPER(product_category) LIKE '%IMMO%'
                OR UPPER(product_category) LIKE '%HOUS%'
                OR UPPER(product_category) LIKE '%HOME%'
             ORDER BY book_date DESC NULLS LAST
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'Immobilier');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 3) corporate
    BEGIN
        SELECT account_number INTO v_acc FROM (
            SELECT account_number FROM cltb_account_apps_master
             WHERE UPPER(product_category) LIKE '%CORP%'
                OR UPPER(product_category) LIKE '%ENTR%'
             ORDER BY amount_financed DESC NULLS LAST
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'Corporate');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 4) particulier
    BEGIN
        SELECT account_number INTO v_acc FROM (
            SELECT account_number FROM cltb_account_apps_master
             WHERE UPPER(product_category) LIKE '%RETAIL%'
                OR UPPER(product_category) LIKE '%PART%'
                OR UPPER(product_category) LIKE '%INDI%'
                OR UPPER(product_category) LIKE '%PERSO%'
             ORDER BY book_date DESC NULLS LAST
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'Particulier');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 5) restructure (best-effort)
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT account_number FROM (
                SELECT account_number FROM cltb_account_apps_master
                 WHERE NVL(reschedule_count,0) > 0
                 ORDER BY book_date DESC
             ) WHERE ROWNUM=1' INTO v_acc;
        add_sample(v_acc,'Restructure');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 6) en souffrance (DPD > 30 sur schedules impayes)
    BEGIN
        SELECT account_number INTO v_acc FROM (
            SELECT s.account_number
              FROM cltb_account_schedules s
              JOIN cltb_account_apps_master m ON m.account_number = s.account_number
             WHERE s.schedule_due_date < TRUNC(SYSDATE) - 30
               AND NVL(s.amount_settled,0) + NVL(s.amount_waived,0) < NVL(s.amount_due,0)
               AND m.account_status NOT IN ('L','C')
             GROUP BY s.account_number
             ORDER BY MIN(s.schedule_due_date)
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'En souffrance (DPD>30)');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 7) solde
    BEGIN
        SELECT account_number INTO v_acc FROM (
            SELECT account_number FROM cltb_account_apps_master
             WHERE account_status IN ('L','C')
             ORDER BY maturity_date DESC NULLS LAST
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'Solde / liquide');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 8) avec penalites
    BEGIN
        SELECT related_account INTO v_acc FROM (
            SELECT related_account, COUNT(*) c
              FROM actb_history
             WHERE module='CL' AND amount_tag LIKE '%PENAL%'
             GROUP BY related_account ORDER BY c DESC
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'Avec penalites');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 9) avec provisions
    BEGIN
        SELECT related_account INTO v_acc FROM (
            SELECT related_account, COUNT(*) c
              FROM actb_history
             WHERE module='CL' AND (amount_tag LIKE '%PROV%' OR amount_tag LIKE '%PRVN%')
             GROUP BY related_account ORDER BY c DESC
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'Avec provisions');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- 10) write-off
    BEGIN
        SELECT related_account INTO v_acc FROM (
            SELECT related_account, COUNT(*) c
              FROM actb_history
             WHERE module='CL' AND (amount_tag LIKE '%WRIT%' OR amount_tag LIKE '%WROF%')
             GROUP BY related_account ORDER BY c DESC
        ) WHERE ROWNUM=1;
        add_sample(v_acc,'Write-off');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- complement par top encours si echantillon < 8
    IF v_idx < 8 THEN
        FOR r IN (
            SELECT account_number FROM (
                SELECT account_number FROM cltb_account_apps_master
                 ORDER BY amount_financed DESC NULLS LAST
            ) WHERE ROWNUM <= 10)
        LOOP
            add_sample(r.account_number,'Top encours');
            EXIT WHEN v_idx >= 10;
        END LOOP;
    END IF;

    p('Echantillon retenu : ' || v_idx || ' dossiers');
    FOR i IN 1..v_idx LOOP
        p('   ['||LPAD(i,2)||'] '|| RPAD(v_sample(i),25) ||' - '|| v_label(i));
    END LOOP;

    --==========================================================================
    -- SECTION C : FICHE CONTRAT PAR DOSSIER (cltb_account_apps_master + cltm_product)
    --==========================================================================
    -- Pour chaque dossier on imprime la "carte d'identite" du credit :
    -- client (CIF + applicant), produit / categorie, dates cles, montants,
    -- comptes de produit (dr_prod_ac = compte de decaissement,
    -- cr_prod_ac = compte de remboursement) et statut.
    --==========================================================================
    section('C','FICHE CONTRAT PAR DOSSIER');

    FOR i IN 1..v_idx LOOP
        subsection('Dossier ['||i||'] '|| v_sample(i) ||' - '|| v_label(i));
        BEGIN
            FOR r IN (
                SELECT m.account_number, m.branch_code, m.customer_id,
                       m.product_code, m.product_category,
                       m.book_date, m.value_date, m.maturity_date,
                       m.amount_financed, m.amount_disbursed,
                       m.primary_applicant_id, m.primary_applicant_name,
                       m.dr_prod_ac, m.cr_prod_ac,
                       m.account_status, m.auth_status,
                       p2.product_desc
                  FROM cltb_account_apps_master m
                  LEFT JOIN cltm_product p2 ON p2.product_code = m.product_code
                 WHERE m.account_number = v_sample(i))
            LOOP
                p('Contrat        : '||r.account_number||' (branch '||r.branch_code||')');
                p('Client (CIF)   : '||r.customer_id||' - '||r.primary_applicant_name
                                       ||' [applicant_id: '||r.primary_applicant_id||']');
                p('Produit        : '||r.product_code||' / '||r.product_desc
                                       ||' (categorie '||r.product_category||')');
                p('Dates          : book='||r.book_date||'  value='||r.value_date
                                          ||'  maturity='||r.maturity_date);
                p('Montants       : finance='||r.amount_financed
                                          ||'  decaisse='||r.amount_disbursed);
                p('Comptes prod   : DR='||r.dr_prod_ac||'  CR='||r.cr_prod_ac);
                p('Statut         : account_status='||r.account_status
                                          ||'  auth_status='||r.auth_status);
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('[contrat] '||SQLERRM); END;
    END LOOP;

    --==========================================================================
    -- SECTION D : UDE - TAUX ET PARAMETRES PAR DOSSIER
    --==========================================================================
    -- cltb_account_ude_values stocke la valeur de chaque User Defined Element
    -- (ex : INT_RATE, PENAL_RATE, MARGIN ...) a une date effective donnee.
    -- Pour reconstituer le taux applicable a une echeance precise, il faudra
    -- joindre par effective_date la plus recente <= date de l'echeance.
    --==========================================================================
    section('D','UDE (TAUX / PARAMETRES) PAR DOSSIER');

    FOR i IN 1..v_idx LOOP
        subsection('UDE dossier ['||i||'] '|| v_sample(i));
        BEGIN
            FOR r IN (
                SELECT effective_date, ude_id, ude_value
                  FROM cltb_account_ude_values
                 WHERE account_number = v_sample(i)
                 ORDER BY effective_date DESC, ude_id)
            LOOP
                p('   '||TO_CHAR(r.effective_date,'DD-MON-YYYY')
                  ||'  '||RPAD(r.ude_id,25)||' = '||r.ude_value);
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('[ude] '||SQLERRM); END;
    END LOOP;

    --==========================================================================
    -- SECTION E : ECHEANCIERS - DUE / SETTLED / WAIVED / DPD
    --==========================================================================
    -- cltb_account_schedules est l'ossature des flux attendus. Une ligne par
    -- echeance et par composante (MAIN_INT, PRINCIPAL, PENALTY ...).
    -- Lecture :
    --   amount_due       = du theorique
    --   amount_settled   = effectivement paye
    --   amount_waived    = remis
    --   reste            = due - settled - waived
    --   dpd              = SYSDATE - schedule_due_date si reste>0 et echu
    --==========================================================================
    section('E','ECHEANCIERS PAR DOSSIER');

    FOR i IN 1..v_idx LOOP
        subsection('Schedules dossier ['||i||'] '|| v_sample(i));
        BEGIN
            p( RPAD('COMPOSANTE',15)||RPAD('DEBUT',13)||RPAD('ECHEANCE',13)
              ||LPAD('DU',16)||LPAD('PAYE',16)||LPAD('REMIS',14)
              ||LPAD('RESTE',16)||LPAD('DPD',6) );
            FOR r IN (
                SELECT component_name, schedule_st_date, schedule_due_date,
                       NVL(amount_due,0)     amount_due,
                       NVL(amount_settled,0) amount_settled,
                       NVL(amount_waived,0)  amount_waived,
                       NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0) reste,
                       CASE WHEN NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0) > 0
                            AND schedule_due_date < TRUNC(SYSDATE)
                            THEN TRUNC(SYSDATE) - schedule_due_date END dpd
                  FROM cltb_account_schedules
                 WHERE account_number = v_sample(i)
                 ORDER BY schedule_due_date, component_name)
            LOOP
                p( RPAD(NVL(r.component_name,' '),15)
                  ||RPAD(NVL(TO_CHAR(r.schedule_st_date,'DD-MON-YY'),' '),13)
                  ||RPAD(NVL(TO_CHAR(r.schedule_due_date,'DD-MON-YY'),' '),13)
                  ||LPAD(TO_CHAR(r.amount_due,'FM999G999G990D00'),16)
                  ||LPAD(TO_CHAR(r.amount_settled,'FM999G999G990D00'),16)
                  ||LPAD(TO_CHAR(r.amount_waived,'FM999G999G990D00'),14)
                  ||LPAD(TO_CHAR(r.reste,'FM999G999G990D00'),16)
                  ||LPAD(NVL(TO_CHAR(r.dpd),'-'),6) );
            END LOOP;
            -- Synthese
            FOR s IN (
                SELECT MAX(CASE WHEN NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0) > 0
                                AND schedule_due_date < TRUNC(SYSDATE)
                                THEN TRUNC(SYSDATE) - schedule_due_date END) max_dpd,
                       SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) tot_reste
                  FROM cltb_account_schedules
                 WHERE account_number = v_sample(i))
            LOOP
                p('Synthese : DPD max = '||NVL(TO_CHAR(s.max_dpd),'0')
                  ||'  Reste a recouvrer = '||TO_CHAR(s.tot_reste,'FM999G999G999G990D00'));
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('[schedules] '||SQLERRM); END;
    END LOOP;

    --==========================================================================
    -- SECTION F : ECRITURES COMPTABLES PAR DOSSIER (actb_history enrichi)
    --==========================================================================
    -- Pour chaque dossier on liste les ecritures chronologiquement, enrichies :
    --   * libelle du tag         (cstb_amount_tag)
    --   * libelle du trn_code    (sttm_trn_code)
    --   * libelle du compte/GL   (sttb_account.ac_gl_desc)
    -- Puis on synthetise les flux par tag (debits, credits, net).
    --==========================================================================
    section('F','ECRITURES COMPTABLES PAR DOSSIER (actb_history)');

    FOR i IN 1..v_idx LOOP
        subsection('Ecritures dossier ['||i||'] '|| v_sample(i));
        BEGIN
            p( RPAD('DATE',12)||RPAD('TRN_REF',20)||RPAD('TRN_CODE',10)
              ||RPAD('TAG',22)||RPAD('AC_NO',22)||RPAD('SENS',5)
              ||LPAD('LCY_AMOUNT',18) );
            FOR r IN (
                SELECT a.trn_dt, a.trn_ref_no, a.trn_code, a.amount_tag,
                       a.ac_no, a.drcr_ind, a.lcy_amount,
                       a.financial_cycle,
                       s.ac_gl_desc, t.trn_desc, ct.description tag_desc
                  FROM actb_history a
                  LEFT JOIN sttb_account s    ON s.ac_no      = a.ac_no
                  LEFT JOIN sttm_trn_code t   ON t.trn_code   = a.trn_code
                  LEFT JOIN cstb_amount_tag ct ON ct.amount_tag = a.amount_tag
                                              AND ct.module    = 'CL'
                 WHERE a.module='CL'
                   AND a.related_account = v_sample(i)
                 ORDER BY a.trn_dt, a.trn_ref_no, a.drcr_ind)
            LOOP
                p( RPAD(TO_CHAR(r.trn_dt,'DD-MON-YY'),12)
                  ||RPAD(NVL(r.trn_ref_no,' '),20)
                  ||RPAD(NVL(r.trn_code,' '),10)
                  ||RPAD(NVL(r.amount_tag,' '),22)
                  ||RPAD(NVL(r.ac_no,' '),22)
                  ||RPAD(NVL(r.drcr_ind,' '),5)
                  ||LPAD(TO_CHAR(r.lcy_amount,'FM999G999G999G990D00'),18) );
            END LOOP;

            -- Synthese par tag (debit, credit, net)
            p(' ');
            p('   Synthese par amount_tag (D-C) :');
            FOR r IN (
                SELECT amount_tag,
                       SUM(CASE WHEN drcr_ind='D' THEN lcy_amount ELSE 0 END) tot_dr,
                       SUM(CASE WHEN drcr_ind='C' THEN lcy_amount ELSE 0 END) tot_cr,
                       COUNT(*) nb
                  FROM actb_history
                 WHERE module='CL' AND related_account = v_sample(i)
                 GROUP BY amount_tag
                 ORDER BY 1)
            LOOP
                p('      '||RPAD(r.amount_tag,25)
                       ||'  D='||LPAD(TO_CHAR(r.tot_dr,'FM999G999G999G990D00'),18)
                       ||'  C='||LPAD(TO_CHAR(r.tot_cr,'FM999G999G999G990D00'),18)
                       ||'  net='||LPAD(TO_CHAR(r.tot_dr-r.tot_cr,'FM999G999G999G990D00'),18)
                       ||'  nb='||r.nb);
            END LOOP;

            -- Focus provisions / write-off / penalites sur ce dossier
            p(' ');
            p('   Focus provisions / write-off / penalites :');
            FOR r IN (
                SELECT trn_dt, amount_tag, drcr_ind, ac_no, lcy_amount, trn_ref_no
                  FROM actb_history
                 WHERE module='CL'
                   AND related_account = v_sample(i)
                   AND (   amount_tag LIKE '%PROV%' OR amount_tag LIKE '%PRVN%'
                        OR amount_tag LIKE '%WRIT%' OR amount_tag LIKE '%WROF%'
                        OR amount_tag LIKE '%PENAL%')
                 ORDER BY trn_dt)
            LOOP
                p('      '||TO_CHAR(r.trn_dt,'DD-MON-YYYY')
                  ||'  '||RPAD(r.amount_tag,22)||'  '||r.drcr_ind
                  ||'  '||RPAD(r.ac_no,22)
                  ||'  '||TO_CHAR(r.lcy_amount,'FM999G999G999G990D00')
                  ||'  ref='||r.trn_ref_no);
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('[actb] '||SQLERRM); END;
    END LOOP;

    --==========================================================================
    -- SECTION G : INVENTAIRE DES AMOUNT_TAG ET TRN_CODE CL UTILISES
    --==========================================================================
    -- Pour comprendre la "grammaire comptable" du module CL dans la banque,
    -- on liste exhaustivement :
    --   G.1 tous les amount_tag rencontres dans actb_history pour module=CL
    --       avec leur libelle (cstb_amount_tag.description)
    --   G.2 tous les trn_code rencontres avec leur libelle (sttm_trn_code)
    -- Ces inventaires sont indispensables pour ecrire la phase 2 d'audit :
    -- savoir quelle famille de tag designe les decaissements, les
    -- remboursements en principal, en interets, les penalites, les
    -- provisions, les reversals, etc.
    --==========================================================================
    section('G','INVENTAIRE AMOUNT_TAG ET TRN_CODE DU MODULE CL');

    subsection('G.1  Amount_tag CL utilises (avec libelle et frequence)');
    BEGIN
        FOR r IN (
            SELECT a.amount_tag, t.description, COUNT(*) nb,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr
              FROM actb_history a
              LEFT JOIN cstb_amount_tag t
                ON t.amount_tag = a.amount_tag AND t.module='CL'
             WHERE a.module='CL'
             GROUP BY a.amount_tag, t.description
             ORDER BY a.amount_tag)
        LOOP
            p('   '||RPAD(r.amount_tag,28)
              ||' '||RPAD(NVL(r.description,'?'),50)
              ||' nb='||LPAD(r.nb,6)
              ||' D='||TO_CHAR(r.tot_dr,'FM999G999G999G990D00')
              ||' C='||TO_CHAR(r.tot_cr,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G1] '||SQLERRM); END;

    subsection('G.2  Trn_code CL utilises (avec libelle et frequence)');
    BEGIN
        FOR r IN (
            SELECT a.trn_code, c.trn_desc, COUNT(*) nb
              FROM actb_history a
              LEFT JOIN sttm_trn_code c ON c.trn_code = a.trn_code
             WHERE a.module='CL'
             GROUP BY a.trn_code, c.trn_desc
             ORDER BY a.trn_code)
        LOOP
            p('   '||RPAD(r.trn_code,8)||' '||RPAD(NVL(r.trn_desc,'?'),70)
              ||' nb='||r.nb);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G2] '||SQLERRM); END;

    --==========================================================================
    -- SECTION H : GL IMPACTES PAR LE MODULE CL
    --==========================================================================
    -- Sur la base d'actb_history joint a sttb_account on cartographie quels
    -- comptes (ou GL) sont mouvementes par le module CL, et les volumes nets.
    -- Le filtre ac_no NOT LIKE '4526%' est repris de votre requete initiale
    -- (exclusion de comptes techniques). On y ajoute la ventilation par
    -- amount_tag pour comprendre quel tag impacte quel GL.
    --==========================================================================
    section('H','GL IMPACTES PAR LE MODULE CL');

    subsection('H.1  GL impactes (hors 4526*) - totaux');
    BEGIN
        FOR r IN (
            SELECT a.ac_no, MAX(s.ac_gl_desc) gl_desc,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr,
                   COUNT(*) nb
              FROM actb_history a
              LEFT JOIN sttb_account s ON s.ac_no = a.ac_no
             WHERE a.module='CL'
               AND a.ac_no NOT LIKE '4526%'
             GROUP BY a.ac_no
             ORDER BY a.ac_no)
        LOOP
            p('   '||RPAD(r.ac_no,22)||' '||RPAD(NVL(r.gl_desc,'?'),50)
              ||' D='||TO_CHAR(r.tot_dr,'FM999G999G999G990D00')
              ||' C='||TO_CHAR(r.tot_cr,'FM999G999G999G990D00')
              ||' nb='||r.nb);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[H1] '||SQLERRM); END;

    subsection('H.2  Croisement amount_tag x GL (mapping reel)');
    -- Ce croisement est essentiel : il permet d'identifier, pour chaque
    -- nature comptable (tag), quels GL sont reellement impactes au debit /
    -- credit. C'est la base pour reconstruire les schemas comptables des
    -- evenements CL et donc des provisions.
    BEGIN
        FOR r IN (
            SELECT a.amount_tag, a.drcr_ind, a.ac_no, MAX(s.ac_gl_desc) gl_desc,
                   COUNT(*) nb, SUM(a.lcy_amount) tot
              FROM actb_history a
              LEFT JOIN sttb_account s ON s.ac_no = a.ac_no
             WHERE a.module='CL'
             GROUP BY a.amount_tag, a.drcr_ind, a.ac_no
             ORDER BY a.amount_tag, a.drcr_ind, a.ac_no)
        LOOP
            p('   tag='||RPAD(r.amount_tag,22)
              ||' sens='||r.drcr_ind
              ||' GL='||RPAD(r.ac_no,22)
              ||' ('||RPAD(NVL(r.gl_desc,'?'),40)||')'
              ||' nb='||LPAD(r.nb,6)
              ||' tot='||TO_CHAR(r.tot,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[H2] '||SQLERRM); END;

    --==========================================================================
    -- SECTION I : INVENTAIRE PRODUITS ET REPARTITION DE L'ENCOURS
    --==========================================================================
    -- Vue 360 sur cltm_product et la repartition du portefeuille credit
    -- par produit / categorie. Permet d'identifier les concentrations.
    --==========================================================================
    section('I','PRODUITS CL ET REPARTITION DU PORTEFEUILLE');

    subsection('I.1  Liste des produits');
    BEGIN
        FOR r IN (
            SELECT p.product_code, p.product_desc, p.product_category,
                   (SELECT COUNT(*) FROM cltb_account_apps_master m
                     WHERE m.product_code = p.product_code) nb_dossiers,
                   (SELECT SUM(amount_disbursed) FROM cltb_account_apps_master m
                     WHERE m.product_code = p.product_code) tot_decaisse
              FROM cltm_product p
             ORDER BY p.product_category, p.product_code)
        LOOP
            p('   '||RPAD(r.product_code,8)||' '||RPAD(r.product_desc,40)
              ||' cat='||RPAD(NVL(r.product_category,'?'),10)
              ||' nb='||LPAD(r.nb_dossiers,6)
              ||' decaisse_total='||TO_CHAR(r.tot_decaisse,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[I1] '||SQLERRM); END;

    subsection('I.2  Repartition par account_status');
    BEGIN
        FOR r IN (
            SELECT account_status, COUNT(*) nb,
                   SUM(amount_financed) tot_finance,
                   SUM(amount_disbursed) tot_decaisse
              FROM cltb_account_apps_master
             GROUP BY account_status
             ORDER BY account_status)
        LOOP
            p('   status='||RPAD(NVL(r.account_status,'?'),4)
              ||' nb='||LPAD(r.nb,6)
              ||' finance='||TO_CHAR(r.tot_finance,'FM999G999G999G990D00')
              ||' decaisse='||TO_CHAR(r.tot_decaisse,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[I2] '||SQLERRM); END;

    --==========================================================================
    -- SECTION J : CONTROLES PRELIMINAIRES TRANSVERSES (PREP PHASE 2)
    --==========================================================================
    -- Quelques rapprochements simples qui orienteront la phase 2 d'audit :
    --   J.1 DPD > 90 j et statut courant : detection des credits qui
    --       sembleraient devoir etre declasses NPL.
    --   J.2 Differentiel DSBR comptable vs amount_disbursed du contrat.
    --   J.3 Dossiers sans aucune ecriture CL (anomalie possible).
    --   J.4 Comptes/GL "provisions" identifies via le pattern de tag
    --       (a affiner avec la maitrise d'ouvrage).
    --==========================================================================
    section('J','CONTROLES PRELIMINAIRES TRANSVERSES (PHASE 2 PREP)');

    subsection('J.1  Top 20 DPD > 90 j non liquides');
    BEGIN
        FOR r IN (
            SELECT m.account_number, m.product_code, m.product_category,
                   m.account_status,
                   MAX(TRUNC(SYSDATE) - s.schedule_due_date) max_dpd,
                   SUM(NVL(s.amount_due,0)-NVL(s.amount_settled,0)-NVL(s.amount_waived,0)) reste
              FROM cltb_account_apps_master m
              JOIN cltb_account_schedules s ON s.account_number = m.account_number
             WHERE m.account_status NOT IN ('L','C')
               AND s.schedule_due_date < TRUNC(SYSDATE) - 90
               AND NVL(s.amount_settled,0) + NVL(s.amount_waived,0) < NVL(s.amount_due,0)
             GROUP BY m.account_number, m.product_code, m.product_category, m.account_status
             ORDER BY max_dpd DESC FETCH FIRST 20 ROWS ONLY)
        LOOP
            p('   '||RPAD(r.account_number,22)
              ||' prod='||RPAD(r.product_code,8)
              ||' cat='||RPAD(NVL(r.product_category,'?'),10)
              ||' status='||RPAD(NVL(r.account_status,'?'),4)
              ||' DPD_max='||LPAD(r.max_dpd,5)
              ||' reste='||TO_CHAR(r.reste,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[J1] '||SQLERRM); END;

    subsection('J.2  Differentiel DSBR comptable vs amount_disbursed (top 20)');
    BEGIN
        FOR r IN (
            SELECT m.account_number, m.amount_disbursed,
                   NVL(a.tot_dsbr,0) tot_dsbr,
                   NVL(a.tot_dsbr,0) - NVL(m.amount_disbursed,0) ecart
              FROM cltb_account_apps_master m
              LEFT JOIN (
                    SELECT related_account,
                           SUM(CASE WHEN drcr_ind='D' THEN lcy_amount ELSE -lcy_amount END) tot_dsbr
                      FROM actb_history
                     WHERE module='CL' AND amount_tag LIKE '%DSBR%'
                     GROUP BY related_account
                   ) a ON a.related_account = m.account_number
             WHERE ABS(NVL(a.tot_dsbr,0) - NVL(m.amount_disbursed,0)) > 0.01
             ORDER BY ABS(NVL(a.tot_dsbr,0) - NVL(m.amount_disbursed,0)) DESC
             FETCH FIRST 20 ROWS ONLY)
        LOOP
            p('   '||RPAD(r.account_number,22)
              ||' contrat='||TO_CHAR(r.amount_disbursed,'FM999G999G999G990D00')
              ||' compta='||TO_CHAR(r.tot_dsbr,'FM999G999G999G990D00')
              ||' ecart='||TO_CHAR(r.ecart,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[J2] '||SQLERRM); END;

    subsection('J.3  Dossiers sans aucune ecriture CL (anomalie ?)');
    BEGIN
        FOR r IN (
            SELECT m.account_number, m.product_code, m.account_status,
                   m.book_date, m.amount_financed
              FROM cltb_account_apps_master m
             WHERE NOT EXISTS (
                    SELECT 1 FROM actb_history a
                     WHERE a.module='CL' AND a.related_account = m.account_number)
               AND m.auth_status = 'A'
             ORDER BY m.book_date DESC NULLS LAST FETCH FIRST 20 ROWS ONLY)
        LOOP
            p('   '||RPAD(r.account_number,22)||' prod='||RPAD(r.product_code,8)
              ||' status='||RPAD(NVL(r.account_status,'?'),4)
              ||' book='||r.book_date
              ||' finance='||TO_CHAR(r.amount_financed,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[J3] '||SQLERRM); END;

    subsection('J.4  Comptes/GL "provisions" identifies via amount_tag');
    -- Identifies les GL distincts touches par des tags %PROV%/%PRVN%/%WRIT%/%WROF%
    BEGIN
        FOR r IN (
            SELECT a.ac_no, MAX(s.ac_gl_desc) gl_desc,
                   LISTAGG(DISTINCT a.amount_tag, ',') WITHIN GROUP (ORDER BY a.amount_tag) tags,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr
              FROM actb_history a
              LEFT JOIN sttb_account s ON s.ac_no = a.ac_no
             WHERE a.module='CL'
               AND (   a.amount_tag LIKE '%PROV%' OR a.amount_tag LIKE '%PRVN%'
                    OR a.amount_tag LIKE '%WRIT%' OR a.amount_tag LIKE '%WROF%')
             GROUP BY a.ac_no
             ORDER BY a.ac_no)
        LOOP
            p('   '||RPAD(r.ac_no,22)||' '||RPAD(NVL(r.gl_desc,'?'),40)
              ||' tags='||r.tags
              ||' D='||TO_CHAR(r.tot_dr,'FM999G999G999G990D00')
              ||' C='||TO_CHAR(r.tot_cr,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[J4] '||SQLERRM); END;

    p(' ');
    p(v_sep);
    p('FIN DE L EXPLORATION PHASE 1');
    p(v_sep);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERREUR GLOBALE : ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
END;
/
