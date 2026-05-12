--==============================================================================
--  PHASE 1 - EXPLORATION DU MODULE CL (FLEXCUBE)
--  Objet : EXTRAIRE les donnees brutes des 8 tables fournies, sans hypothese
--          sur les valeurs (tags, codes, statuts, categories).
--          La comprehension fonctionnelle viendra de la lecture des sorties.
--
--  Tables (uniquement) :
--      cltb_account_apps_master, cltb_account_schedules,
--      cltb_account_ude_values,  cltm_product,
--      actb_history, sttb_account, cstb_amount_tag, sttm_trn_code
--
--  Mode d'execution :
--      SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
--      SET LINESIZE 400
--      ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-YYYY';
--      @phase1_exploration_cl.sql
--
--  Principe : aucun filtre LIKE '%XXX%' sur les tags / categories / statuts.
--  On enumere toutes les valeurs presentes, on compte, on agrege.
--  L'echantillon de dossiers est constitue uniquement sur des criteres
--  neutres (volumetrie, anciennete, montant, diversite par cle parente).
--==============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 400
SET PAGESIZE 0
SET FEEDBACK OFF
SET VERIFY OFF
ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-YYYY';
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

DECLARE
    TYPE t_acc_list IS TABLE OF VARCHAR2(35) INDEX BY PLS_INTEGER;
    v_sample        t_acc_list;
    v_reason        t_acc_list;
    v_idx           PLS_INTEGER := 0;
    v_sep           CONSTANT VARCHAR2(120) := RPAD('=',120,'=');
    v_sub           CONSTANT VARCHAR2(120) := RPAD('-',120,'-');

    PROCEDURE p(t VARCHAR2) IS
    BEGIN
        IF t IS NULL THEN DBMS_OUTPUT.PUT_LINE(' '); RETURN; END IF;
        FOR i IN 0 .. CEIL(LENGTH(t)/250)-1 LOOP
            DBMS_OUTPUT.PUT_LINE( SUBSTR(t, i*250+1, 250) );
        END LOOP;
    END;

    PROCEDURE section(c VARCHAR2, t VARCHAR2) IS
    BEGIN p(' '); p(v_sep); p('SECTION '||c||' : '||t); p(v_sep); END;

    PROCEDURE subsection(t VARCHAR2) IS
    BEGIN p(' '); p(v_sub); p('>> '||t); p(v_sub); END;

    FUNCTION cnt(p_tab VARCHAR2, p_where VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        n NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM '||p_tab
            ||CASE WHEN p_where IS NOT NULL THEN ' WHERE '||p_where END INTO n;
        RETURN TO_CHAR(n);
    EXCEPTION WHEN OTHERS THEN RETURN '[err '||SQLCODE||']'; END;

    -- Ajoute un dossier a l'echantillon si pas deja present
    PROCEDURE add_sample(p_acc VARCHAR2, p_reason VARCHAR2) IS
        v_found BOOLEAN := FALSE;
    BEGIN
        IF p_acc IS NULL THEN RETURN; END IF;
        FOR i IN 1..v_idx LOOP
            IF v_sample(i)=p_acc THEN v_found:=TRUE; EXIT; END IF;
        END LOOP;
        IF NOT v_found AND v_idx<10 THEN
            v_idx := v_idx+1;
            v_sample(v_idx) := p_acc;
            v_reason(v_idx) := p_reason;
        END IF;
    END;

BEGIN
    p(v_sep);
    p('EXPLORATION FLEXCUBE MODULE CL - PHASE 1 (extraction sans hypothese)');
    p('Date : '||TO_CHAR(SYSDATE,'DD-MON-YYYY HH24:MI:SS'));
    p('Schema : '||SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
    p(v_sep);

    --==========================================================================
    -- SECTION A : STRUCTURE DES TABLES (colonnes, types)
    --==========================================================================
    -- On lit ALL_TAB_COLUMNS pour les 8 tables. Sortie : nom, type, nullable.
    -- Permet de visualiser la structure reelle (le nom des colonnes varie
    -- selon les patches FLEXCUBE).
    --==========================================================================
    section('A','STRUCTURE DES 8 TABLES (colonnes / types)');

    FOR t IN (SELECT column_value tn FROM TABLE(SYS.ODCIVARCHAR2LIST(
        'CLTB_ACCOUNT_APPS_MASTER','CLTB_ACCOUNT_SCHEDULES',
        'CLTB_ACCOUNT_UDE_VALUES','CLTM_PRODUCT',
        'ACTB_HISTORY','STTB_ACCOUNT',
        'CSTB_AMOUNT_TAG','STTM_TRN_CODE')))
    LOOP
        subsection(t.tn);
        BEGIN
            FOR c IN (
                SELECT column_name, data_type, data_length, nullable, column_id
                  FROM user_tab_columns
                 WHERE table_name = t.tn
                 ORDER BY column_id)
            LOOP
                p('   '||LPAD(c.column_id,3)||' '||RPAD(c.column_name,35)
                  ||' '||RPAD(c.data_type||CASE WHEN c.data_type LIKE 'VARCHAR%'
                                                THEN '('||c.data_length||')' END,18)
                  ||' '||c.nullable);
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;
    END LOOP;

    --==========================================================================
    -- SECTION B : VOLUMETRIE
    --==========================================================================
    section('B','VOLUMETRIE');

    p( RPAD('cltb_account_apps_master',32)||' : '||cnt('cltb_account_apps_master') );
    p( RPAD('cltb_account_schedules',32)  ||' : '||cnt('cltb_account_schedules') );
    p( RPAD('cltb_account_ude_values',32) ||' : '||cnt('cltb_account_ude_values') );
    p( RPAD('cltm_product',32)            ||' : '||cnt('cltm_product') );
    p( RPAD('actb_history',32)            ||' : '||cnt('actb_history') );
    p( RPAD('actb_history (module=CL)',32)||' : '||cnt('actb_history','module=''CL''') );
    p( RPAD('sttb_account',32)            ||' : '||cnt('sttb_account') );
    p( RPAD('cstb_amount_tag',32)         ||' : '||cnt('cstb_amount_tag') );
    p( RPAD('cstb_amount_tag (module=CL)',32)||' : '||cnt('cstb_amount_tag','module=''CL''') );
    p( RPAD('sttm_trn_code',32)           ||' : '||cnt('sttm_trn_code') );

    --==========================================================================
    -- SECTION C : DISTRIBUTIONS DES VALEURS DISCRETES
    --==========================================================================
    -- On laisse parler les donnees : pour chaque colonne susceptible d'etre un
    -- code metier, on liste toutes les valeurs distinctes avec leur frequence.
    -- Cela permet ENSUITE (phase 2) de decider ce qui designe une provision,
    -- un decaissement, une penalite, etc.
    --==========================================================================
    section('C','DISTRIBUTIONS DES VALEURS DISCRETES (sans filtre)');

    subsection('C.1  cltm_product.product_category (toutes valeurs)');
    BEGIN
        FOR r IN (
            SELECT product_category, COUNT(*) nb
              FROM cltm_product GROUP BY product_category ORDER BY 2 DESC)
        LOOP p('   '||RPAD(NVL(r.product_category,'<null>'),20)||' nb='||r.nb); END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.2  cltm_product (liste complete : code / desc / categorie)');
    BEGIN
        FOR r IN (SELECT product_code, product_desc, product_category
                    FROM cltm_product ORDER BY product_category, product_code)
        LOOP
            p('   '||RPAD(r.product_code,10)||' '||RPAD(NVL(r.product_desc,'?'),50)
              ||' cat='||r.product_category);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.3  cltb_account_apps_master.account_status (toutes valeurs)');
    BEGIN
        FOR r IN (
            SELECT account_status, COUNT(*) nb,
                   SUM(amount_financed) tot_fin,
                   SUM(amount_disbursed) tot_dec
              FROM cltb_account_apps_master
             GROUP BY account_status ORDER BY 2 DESC)
        LOOP
            p('   '||RPAD(NVL(r.account_status,'<null>'),6)||' nb='||LPAD(r.nb,6)
              ||' finance='||TO_CHAR(r.tot_fin,'FM999G999G999G990D00')
              ||' decaisse='||TO_CHAR(r.tot_dec,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.4  cltb_account_apps_master.auth_status (toutes valeurs)');
    BEGIN
        FOR r IN (SELECT auth_status, COUNT(*) nb FROM cltb_account_apps_master
                   GROUP BY auth_status ORDER BY 2 DESC)
        LOOP p('   '||RPAD(NVL(r.auth_status,'<null>'),6)||' nb='||r.nb); END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.5  cltb_account_apps_master.product_category (toutes valeurs)');
    BEGIN
        FOR r IN (
            SELECT product_category, COUNT(*) nb,
                   SUM(amount_financed) tot_fin
              FROM cltb_account_apps_master
             GROUP BY product_category ORDER BY 2 DESC)
        LOOP
            p('   '||RPAD(NVL(r.product_category,'<null>'),20)
              ||' nb='||LPAD(r.nb,6)
              ||' finance_total='||TO_CHAR(r.tot_fin,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.6  cltb_account_apps_master.product_code (top 30)');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT product_code, COUNT(*) nb,
                       SUM(amount_financed) tot_fin
                  FROM cltb_account_apps_master
                 GROUP BY product_code
                 ORDER BY 2 DESC
            ) WHERE ROWNUM <= 30)
        LOOP
            p('   '||RPAD(r.product_code,10)||' nb='||LPAD(r.nb,6)
              ||' finance_total='||TO_CHAR(r.tot_fin,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.7  cltb_account_schedules.component_name (toutes valeurs)');
    BEGIN
        FOR r IN (
            SELECT component_name, COUNT(*) nb,
                   SUM(amount_due) tot_due,
                   SUM(amount_settled) tot_set,
                   SUM(amount_waived) tot_wai
              FROM cltb_account_schedules
             GROUP BY component_name ORDER BY 2 DESC)
        LOOP
            p('   '||RPAD(NVL(r.component_name,'<null>'),25)||' nb='||LPAD(r.nb,7)
              ||' du='||TO_CHAR(r.tot_due,'FM999G999G999G990D00')
              ||' paye='||TO_CHAR(r.tot_set,'FM999G999G999G990D00')
              ||' remis='||TO_CHAR(r.tot_wai,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.8  cltb_account_ude_values.ude_id (toutes valeurs)');
    BEGIN
        FOR r IN (
            SELECT ude_id, COUNT(*) nb,
                   MIN(ude_value) min_val, MAX(ude_value) max_val
              FROM cltb_account_ude_values
             GROUP BY ude_id ORDER BY 2 DESC)
        LOOP
            p('   '||RPAD(NVL(r.ude_id,'<null>'),25)||' nb='||LPAD(r.nb,7)
              ||' min='||r.min_val||' max='||r.max_val);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.9  actb_history.module (toutes valeurs)');
    BEGIN
        FOR r IN (SELECT module, COUNT(*) nb FROM actb_history
                   GROUP BY module ORDER BY 2 DESC)
        LOOP p('   '||RPAD(NVL(r.module,'<null>'),8)||' nb='||r.nb); END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.10  actb_history.amount_tag pour module=CL (toutes valeurs)');
    -- AUCUN FILTRE : on liste exhaustivement les tags CL avec libelle et flux
    BEGIN
        FOR r IN (
            SELECT a.amount_tag, t.description,
                   COUNT(*) nb,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr
              FROM actb_history a
              LEFT JOIN cstb_amount_tag t
                ON t.amount_tag = a.amount_tag AND t.module='CL'
             WHERE a.module='CL'
             GROUP BY a.amount_tag, t.description
             ORDER BY a.amount_tag)
        LOOP
            p('   '||RPAD(NVL(r.amount_tag,'<null>'),30)
              ||' '||RPAD(NVL(r.description,'<no desc>'),50)
              ||' nb='||LPAD(r.nb,7)
              ||' D='||TO_CHAR(r.tot_dr,'FM999G999G999G990D00')
              ||' C='||TO_CHAR(r.tot_cr,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.11  actb_history.trn_code pour module=CL (toutes valeurs)');
    BEGIN
        FOR r IN (
            SELECT a.trn_code, c.trn_desc, COUNT(*) nb
              FROM actb_history a
              LEFT JOIN sttm_trn_code c ON c.trn_code = a.trn_code
             WHERE a.module='CL'
             GROUP BY a.trn_code, c.trn_desc ORDER BY a.trn_code)
        LOOP
            p('   '||RPAD(NVL(r.trn_code,'<null>'),10)
              ||' '||RPAD(NVL(r.trn_desc,'<no desc>'),70)
              ||' nb='||r.nb);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.12  actb_history.drcr_ind pour module=CL');
    BEGIN
        FOR r IN (SELECT drcr_ind, COUNT(*) nb, SUM(lcy_amount) tot
                    FROM actb_history WHERE module='CL'
                   GROUP BY drcr_ind ORDER BY drcr_ind)
        LOOP
            p('   '||RPAD(NVL(r.drcr_ind,'<null>'),3)||' nb='||LPAD(r.nb,8)
              ||' total='||TO_CHAR(r.tot,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('C.13  actb_history.financial_cycle pour module=CL');
    BEGIN
        FOR r IN (SELECT financial_cycle, COUNT(*) nb FROM actb_history
                   WHERE module='CL' GROUP BY financial_cycle ORDER BY 1)
        LOOP p('   '||RPAD(NVL(r.financial_cycle,'<null>'),10)||' nb='||r.nb); END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION D : CONSTITUTION DE L'ECHANTILLON (criteres NEUTRES)
    --==========================================================================
    -- Aucun filtre par patterns metier. On choisit la diversite sur des axes
    -- structurels :
    --   D.1 Un dossier par account_status distinct
    --   D.2 Un dossier par product_category distinct
    --   D.3 Le dossier avec le plus de schedules
    --   D.4 Le dossier avec le plus d'ecritures comptables
    --   D.5 Plus gros amount_financed, plus petit amount_financed
    --   D.6 Plus ancien (book_date min), plus recent (book_date max)
    -- Capacite max = 10.
    --==========================================================================
    section('D','SELECTION DE L ECHANTILLON (criteres neutres)');

    -- D.1 : un par account_status
    BEGIN
        FOR s IN (SELECT DISTINCT account_status FROM cltb_account_apps_master) LOOP
            BEGIN
                DECLARE v_acc VARCHAR2(35);
                BEGIN
                    SELECT account_number INTO v_acc FROM (
                        SELECT account_number FROM cltb_account_apps_master
                         WHERE NVL(account_status,'~') = NVL(s.account_status,'~')
                         ORDER BY book_date DESC NULLS LAST
                    ) WHERE ROWNUM=1;
                    add_sample(v_acc, 'status='||NVL(s.account_status,'<null>'));
                END;
            EXCEPTION WHEN OTHERS THEN NULL; END;
            EXIT WHEN v_idx >= 10;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- D.2 : un par product_category
    IF v_idx < 10 THEN
        BEGIN
            FOR s IN (SELECT DISTINCT product_category FROM cltb_account_apps_master) LOOP
                BEGIN
                    DECLARE v_acc VARCHAR2(35);
                    BEGIN
                        SELECT account_number INTO v_acc FROM (
                            SELECT account_number FROM cltb_account_apps_master
                             WHERE NVL(product_category,'~') = NVL(s.product_category,'~')
                             ORDER BY amount_financed DESC NULLS LAST
                        ) WHERE ROWNUM=1;
                        add_sample(v_acc, 'cat='||NVL(s.product_category,'<null>'));
                    END;
                EXCEPTION WHEN OTHERS THEN NULL; END;
                EXIT WHEN v_idx >= 10;
            END LOOP;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    -- D.3 : dossier avec le plus de schedules
    IF v_idx < 10 THEN
        BEGIN
            DECLARE v_acc VARCHAR2(35);
            BEGIN
                SELECT account_number INTO v_acc FROM (
                    SELECT account_number, COUNT(*) c FROM cltb_account_schedules
                     GROUP BY account_number ORDER BY c DESC
                ) WHERE ROWNUM=1;
                add_sample(v_acc, 'max schedules');
            END;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    -- D.4 : dossier avec le plus d'ecritures comptables CL
    IF v_idx < 10 THEN
        BEGIN
            DECLARE v_acc VARCHAR2(35);
            BEGIN
                SELECT related_account INTO v_acc FROM (
                    SELECT related_account, COUNT(*) c FROM actb_history
                     WHERE module='CL' AND related_account IS NOT NULL
                     GROUP BY related_account ORDER BY c DESC
                ) WHERE ROWNUM=1;
                add_sample(v_acc, 'max ecritures CL');
            END;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    -- D.5 : plus gros / plus petit amount_financed
    IF v_idx < 10 THEN
        BEGIN
            DECLARE v_acc VARCHAR2(35);
            BEGIN
                SELECT account_number INTO v_acc FROM (
                    SELECT account_number FROM cltb_account_apps_master
                     WHERE amount_financed IS NOT NULL
                     ORDER BY amount_financed DESC
                ) WHERE ROWNUM=1;
                add_sample(v_acc, 'max amount_financed');
            END;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
    IF v_idx < 10 THEN
        BEGIN
            DECLARE v_acc VARCHAR2(35);
            BEGIN
                SELECT account_number INTO v_acc FROM (
                    SELECT account_number FROM cltb_account_apps_master
                     WHERE amount_financed IS NOT NULL AND amount_financed > 0
                     ORDER BY amount_financed ASC
                ) WHERE ROWNUM=1;
                add_sample(v_acc, 'min amount_financed');
            END;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    -- D.6 : plus ancien / plus recent (book_date)
    IF v_idx < 10 THEN
        BEGIN
            DECLARE v_acc VARCHAR2(35);
            BEGIN
                SELECT account_number INTO v_acc FROM (
                    SELECT account_number FROM cltb_account_apps_master
                     WHERE book_date IS NOT NULL ORDER BY book_date ASC
                ) WHERE ROWNUM=1;
                add_sample(v_acc, 'plus ancien book_date');
            END;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
    IF v_idx < 10 THEN
        BEGIN
            DECLARE v_acc VARCHAR2(35);
            BEGIN
                SELECT account_number INTO v_acc FROM (
                    SELECT account_number FROM cltb_account_apps_master
                     WHERE book_date IS NOT NULL ORDER BY book_date DESC
                ) WHERE ROWNUM=1;
                add_sample(v_acc, 'plus recent book_date');
            END;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    p('Echantillon retenu : '||v_idx||' dossiers');
    FOR i IN 1..v_idx LOOP
        p('   ['||LPAD(i,2)||'] '||RPAD(v_sample(i),25)||' - '||v_reason(i));
    END LOOP;

    --==========================================================================
    -- SECTION E : POUR CHAQUE DOSSIER - TOUTES LES LIGNES DES 5 TABLES LIEES
    --==========================================================================
    -- On extrait les donnees TELLES QUELLES, sans interpretation :
    --   E.1 cltb_account_apps_master  (toutes les colonnes "metier")
    --   E.2 cltm_product              (produit du dossier)
    --   E.3 cltb_account_ude_values   (toutes les lignes)
    --   E.4 cltb_account_schedules    (toutes les lignes)
    --   E.5 actb_history              (toutes les lignes module=CL liees)
    --==========================================================================
    section('E','EXTRACTION COMPLETE PAR DOSSIER (sans filtre)');

    FOR i IN 1..v_idx LOOP
        subsection('Dossier ['||i||'] '||v_sample(i)||' - '||v_reason(i));

        -- E.1 contrat
        BEGIN
            FOR r IN (SELECT m.* FROM cltb_account_apps_master m
                       WHERE m.account_number = v_sample(i)) LOOP
                p('   account_number       = '||r.account_number);
                p('   branch_code          = '||r.branch_code);
                p('   customer_id          = '||r.customer_id);
                p('   product_code         = '||r.product_code);
                p('   product_category     = '||r.product_category);
                p('   book_date            = '||r.book_date);
                p('   value_date           = '||r.value_date);
                p('   maturity_date        = '||r.maturity_date);
                p('   amount_financed      = '||r.amount_financed);
                p('   amount_disbursed     = '||r.amount_disbursed);
                p('   primary_applicant_id = '||r.primary_applicant_id);
                p('   primary_applicant_nm = '||r.primary_applicant_name);
                p('   dr_prod_ac           = '||r.dr_prod_ac);
                p('   cr_prod_ac           = '||r.cr_prod_ac);
                p('   account_status       = '||r.account_status);
                p('   auth_status          = '||r.auth_status);
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('   [contrat err] '||SQLERRM); END;

        -- E.2 produit
        BEGIN
            FOR r IN (SELECT p2.* FROM cltm_product p2
                       WHERE p2.product_code = (SELECT product_code
                                                   FROM cltb_account_apps_master
                                                  WHERE account_number = v_sample(i))) LOOP
                p('   --- produit ---');
                p('   product_code     = '||r.product_code);
                p('   product_desc     = '||r.product_desc);
                p('   product_category = '||r.product_category);
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('   [produit err] '||SQLERRM); END;

        -- E.3 UDE (toutes les lignes, sans filtre)
        BEGIN
            p('   --- UDE (cltb_account_ude_values) ---');
            FOR r IN (SELECT effective_date, ude_id, ude_value
                        FROM cltb_account_ude_values
                       WHERE account_number = v_sample(i)
                       ORDER BY effective_date, ude_id) LOOP
                p('      '||TO_CHAR(r.effective_date,'DD-MON-YYYY')
                  ||' '||RPAD(r.ude_id,25)||' = '||r.ude_value);
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('   [ude err] '||SQLERRM); END;

        -- E.4 schedules (toutes les lignes)
        BEGIN
            p('   --- schedules (cltb_account_schedules) ---');
            p('   '||RPAD('component_name',20)||RPAD('st_date',13)||RPAD('due_date',13)
              ||LPAD('amount_due',16)||LPAD('amount_settled',16)||LPAD('amount_waived',16));
            FOR r IN (
                SELECT component_name, schedule_st_date, schedule_due_date,
                       amount_due, amount_settled, amount_waived
                  FROM cltb_account_schedules
                 WHERE account_number = v_sample(i)
                 ORDER BY schedule_due_date, component_name) LOOP
                p('   '||RPAD(NVL(r.component_name,' '),20)
                  ||RPAD(NVL(TO_CHAR(r.schedule_st_date,'DD-MON-YY'),' '),13)
                  ||RPAD(NVL(TO_CHAR(r.schedule_due_date,'DD-MON-YY'),' '),13)
                  ||LPAD(NVL(TO_CHAR(r.amount_due,'FM999G999G990D00'),' '),16)
                  ||LPAD(NVL(TO_CHAR(r.amount_settled,'FM999G999G990D00'),' '),16)
                  ||LPAD(NVL(TO_CHAR(r.amount_waived,'FM999G999G990D00'),' '),16));
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('   [schedules err] '||SQLERRM); END;

        -- E.5 ecritures comptables liees (toutes, sans filtre sur tag)
        BEGIN
            p('   --- ecritures (actb_history, module=CL) ---');
            p('   '||RPAD('trn_dt',12)||RPAD('trn_ref_no',22)||RPAD('trn_code',10)
              ||RPAD('amount_tag',25)||RPAD('ac_no',22)||RPAD('drcr',5)
              ||LPAD('lcy_amount',18)||' ac_gl_desc');
            FOR r IN (
                SELECT a.trn_dt, a.trn_ref_no, a.trn_code, a.amount_tag,
                       a.ac_no, a.drcr_ind, a.lcy_amount,
                       s.ac_gl_desc
                  FROM actb_history a
                  LEFT JOIN sttb_account s ON s.ac_no = a.ac_no
                 WHERE a.module='CL'
                   AND a.related_account = v_sample(i)
                 ORDER BY a.trn_dt, a.trn_ref_no, a.drcr_ind) LOOP
                p('   '||RPAD(NVL(TO_CHAR(r.trn_dt,'DD-MON-YY'),' '),12)
                  ||RPAD(NVL(r.trn_ref_no,' '),22)
                  ||RPAD(NVL(r.trn_code,' '),10)
                  ||RPAD(NVL(r.amount_tag,' '),25)
                  ||RPAD(NVL(r.ac_no,' '),22)
                  ||RPAD(NVL(r.drcr_ind,' '),5)
                  ||LPAD(NVL(TO_CHAR(r.lcy_amount,'FM999G999G999G990D00'),' '),18)
                  ||' '||NVL(r.ac_gl_desc,' '));
            END LOOP;
        EXCEPTION WHEN OTHERS THEN p('   [actb err] '||SQLERRM); END;
    END LOOP;

    --==========================================================================
    -- SECTION F : CROISEMENTS BRUTS POUR LECTURE DE LA "GRAMMAIRE COMPTABLE"
    --==========================================================================
    -- Sans aucune interpretation, on liste toutes les combinaisons distinctes
    -- effectivement presentes dans la base, ce qui revele la grammaire reelle.
    --==========================================================================
    section('F','CROISEMENTS BRUTS (toutes combinaisons distinctes)');

    subsection('F.1  trn_code x amount_tag (module=CL)');
    BEGIN
        FOR r IN (
            SELECT a.trn_code, c.trn_desc, a.amount_tag, t.description tag_desc,
                   COUNT(*) nb,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr
              FROM actb_history a
              LEFT JOIN sttm_trn_code c    ON c.trn_code   = a.trn_code
              LEFT JOIN cstb_amount_tag t  ON t.amount_tag = a.amount_tag
                                          AND t.module    = 'CL'
             WHERE a.module='CL'
             GROUP BY a.trn_code, c.trn_desc, a.amount_tag, t.description
             ORDER BY a.trn_code, a.amount_tag)
        LOOP
            p('   trn='||RPAD(NVL(r.trn_code,'?'),8)||' ('||RPAD(NVL(r.trn_desc,'?'),30)||')'
              ||' tag='||RPAD(NVL(r.amount_tag,'?'),25)||' ('||RPAD(NVL(r.tag_desc,'?'),30)||')'
              ||' nb='||LPAD(r.nb,6)
              ||' D='||TO_CHAR(r.tot_dr,'FM999G999G999G990D00')
              ||' C='||TO_CHAR(r.tot_cr,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [F1 err] '||SQLERRM); END;

    subsection('F.2  amount_tag x drcr_ind x ac_no (module=CL)');
    BEGIN
        FOR r IN (
            SELECT a.amount_tag, a.drcr_ind, a.ac_no, s.ac_gl_desc,
                   COUNT(*) nb, SUM(a.lcy_amount) tot
              FROM actb_history a
              LEFT JOIN sttb_account s ON s.ac_no = a.ac_no
             WHERE a.module='CL'
             GROUP BY a.amount_tag, a.drcr_ind, a.ac_no, s.ac_gl_desc
             ORDER BY a.amount_tag, a.drcr_ind, a.ac_no)
        LOOP
            p('   tag='||RPAD(NVL(r.amount_tag,'?'),25)
              ||' sens='||r.drcr_ind
              ||' ac='||RPAD(NVL(r.ac_no,'?'),22)
              ||' ('||RPAD(NVL(r.ac_gl_desc,'?'),35)||')'
              ||' nb='||LPAD(r.nb,6)
              ||' tot='||TO_CHAR(r.tot,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [F2 err] '||SQLERRM); END;

    subsection('F.3  product_code x amount_tag (module=CL)');
    -- Quels tags sont actives par quels produits ? Sans suppositions.
    BEGIN
        FOR r IN (
            SELECT m.product_code, a.amount_tag, COUNT(*) nb,
                   SUM(a.lcy_amount) tot
              FROM actb_history a
              JOIN cltb_account_apps_master m
                ON m.account_number = a.related_account
             WHERE a.module='CL'
             GROUP BY m.product_code, a.amount_tag
             ORDER BY m.product_code, a.amount_tag)
        LOOP
            p('   prod='||RPAD(r.product_code,10)
              ||' tag='||RPAD(NVL(r.amount_tag,'?'),25)
              ||' nb='||LPAD(r.nb,6)
              ||' tot='||TO_CHAR(r.tot,'FM999G999G999G990D00'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [F3 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION G : REFERENTIELS COMPLETS
    --==========================================================================
    -- Liste exhaustive des libelles disponibles dans les deux referentiels
    -- joints. Ces dictionnaires sont la cle de lecture de toutes les sorties
    -- precedentes.
    --==========================================================================
    section('G','REFERENTIELS COMPLETS');

    subsection('G.1  cstb_amount_tag (module=CL)');
    BEGIN
        FOR r IN (SELECT amount_tag, description FROM cstb_amount_tag
                   WHERE module='CL' ORDER BY amount_tag) LOOP
            p('   '||RPAD(r.amount_tag,30)||' '||NVL(r.description,'?'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    subsection('G.2  sttm_trn_code utilises par CL');
    BEGIN
        FOR r IN (
            SELECT trn_code, trn_desc FROM sttm_trn_code
             WHERE trn_code IN (SELECT DISTINCT trn_code FROM actb_history WHERE module='CL')
             ORDER BY trn_code) LOOP
            p('   '||RPAD(r.trn_code,10)||' '||NVL(r.trn_desc,'?'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('   [err] '||SQLERRM); END;

    p(' ');
    p(v_sep);
    p('FIN EXPLORATION PHASE 1');
    p(v_sep);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERREUR GLOBALE : '||SQLERRM);
        DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
END;
/
