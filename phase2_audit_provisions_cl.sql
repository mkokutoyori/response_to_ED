--==============================================================================
--  PHASE 2 - AUDIT DES PROVISIONS SUR CREDITS - FLEXCUBE MODULE CL
--  Banque : SCB Cameroun (FCUBSLIVE) - OHADA / reglementation BEAC-COBAC
--
--  Perimetre confirme par la phase 1 :
--    1) Classement creances + reserves d'interets (classe 9 OHADA)
--    2) Dotations aux depreciations (comptes 29x / 39x / 491x)
--    3) Reconciliation comptes GL vs encours CL
--    4) Audit des taux UDE et du parametrage
--
--  Seuils BEAC adoptes (modifiables dans la section A) :
--    NORM        DPD <  30 j
--    WACH        DPD 30-89 j      (sous-surveillance)
--    SUBSTANDARD DPD 90-179 j     (substandard / irrecouvrable a 25%)
--    DOUBTFUL    DPD 180-365 j    (douteux / 50%)
--    LOSS        DPD > 365 j      (compromis / 100%)
--
--  Tables utilisees (perimetre phase 1, etendu uniquement aux jointures
--  necessaires) :
--    cltb_account_apps_master, cltb_account_schedules,
--    cltb_account_ude_values, cltm_product,
--    actb_history, sttb_account, cstb_amount_tag, sttm_trn_code
--
--  Mode d'execution :
--    SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
--    SET LINESIZE 400
--    ALTER SESSION SET NLS_DATE_FORMAT='DD-MON-YYYY';
--    @phase2_audit_provisions_cl.sql
--
--  Architecture comptable identifiee a la phase 1 (pour rappel) :
--    Decaissement      tag PRINCIPAL                DR 311500100/321xxx  CR 452600001
--    Accrual interets  tag MAIN_INT_ACCR            DR 318000100         CR 712xxx
--    Remb. interets    tag MAIN_INT_LIQD            inverse
--    Remb. capital     tag PRINCIPAL_LIQD           inverse
--    Penalites         tags ODIN_PNLTY_*, ODPR_*    DR 318000100 / 712xxx, CR 719000103
--    TVA               tag TVA_MAININT_LIQD         CR 434000131
--    Reserve interets  tag MAIN_INT_SACR            DR 985100100 CR 997100100  (cl.9)
--    Reclassements     tags _NORM_REAL/_WACH_REAL   transferts 318000100<->318000105 etc.
--
--  Constat de phase 1 : aucun tag CL ne porte une dotation aux depreciations
--  (comptes 29x/39x). Si elles existent, elles sont passees hors CL (manuel
--  ou autre module). La section G les detecte et le module createur est
--  identifie.
--==============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 400
SET PAGESIZE 0
SET FEEDBACK OFF
SET VERIFY OFF
ALTER SESSION SET NLS_DATE_FORMAT='DD-MON-YYYY';
ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,';

DECLARE
    --==========================================================================
    -- SECTION A : PARAMETRES (modifiables avant execution)
    --==========================================================================
    g_ref_date          DATE   := TRUNC(SYSDATE);            -- date d'evaluation
    g_dpd_wach          NUMBER := 30;                         -- seuil WACH
    g_dpd_sub           NUMBER := 90;                         -- seuil SUBSTANDARD
    g_dpd_doubt         NUMBER := 180;                        -- seuil DOUBTFUL
    g_dpd_loss          NUMBER := 365;                        -- seuil LOSS
    g_tol_accr_pct      NUMBER := 0.05;                       -- tolerance audit accrual (5%)
    g_tol_recon         NUMBER := 1;                          -- tolerance reconciliation (1 FCFA)
    g_top_n             NUMBER := 25;                         -- nb lignes details

    -- Comptes / patterns ac_no (deduits de la phase 1 + cycle de vie OHADA)
    g_re_credit_sain    VARCHAR2(40) := '^(311|321)[0-9]{6}0$';     -- creances saines
    g_re_credit_irreg   VARCHAR2(40) := '^(318|328)[0-9]{5}5$';     -- WACH / irregulieres
    g_re_credit_doubt   VARCHAR2(40) := '^(328[0-9]{5}8|345)';      -- creances rattachees douteuses
    g_re_creanc_ratt    VARCHAR2(40) := '^(318|328)[0-9]{6}$';      -- creances rattachees (int.)
    g_re_int_reserve_dr VARCHAR2(40) := '^985[0-9]{6}$';            -- DR reserve interets
    g_re_int_reserve_cr VARCHAR2(40) := '^997[0-9]{6}$';            -- CR reserve interets
    g_re_revenue_int    VARCHAR2(40) := '^71[0-9]{6}$';             -- compte produits interets
    -- Cycle de vie PCEC COBAC des provisions sur creances clientele
    -- (codes corriges suite a la decouverte ac_no SCB Cameroun)
    --
    -- Reference PCEC COBAC R-98/01 :
    --   34x   Creances en souffrance         (341 impayees, 342 immobilisees,
    --                                         343 doute_gar_Etat, 344 doute_gar_suretes,
    --                                         345 autres doute, 346/347 credit-bail)
    --   39x   Provisions depreciation clientele (391-396)
    --   691   Dotations aux provisions       (6913 specifique clientele en theorie,
    --                                         mais SCB n'utilise que 691 a 3 chiffres)
    --   791   Reprises de provisions         (7913 en theorie, agrege en 791 chez SCB)
    --   792   Rentrees sur creances abandonnees (PCEC les assimile aux reprises)
    --   985   Interets reserves sur creances en souffrance (hors bilan)
    --   997   Interets et commissions reservees (contrepartie hors bilan)
    --
    -- Specificite SCB : les pertes sur creances irrecouvrables sont enregistrees
    -- en compte 679 "PERTE SUR OPS CLIENTELE" (et non en 6921/6922 du PCEC standard).
    -- Il n'y a donc PAS de distinction couvert/non couvert au niveau comptable.
    -- On laisse neanmoins le pattern accepter 6921/6922 par defense en cas
    -- d'evolution future.
    g_re_creanc_souff   VARCHAR2(40) := '^34[0-9]+$';
    g_re_provisions     VARCHAR2(40) := '^39[0-9]+$';
    g_re_dotations      VARCHAR2(40) := '^691[0-9]*$';              -- corrige : 691 et non 693
    g_re_reprises       VARCHAR2(40) := '^79[12][0-9]*$';           -- corrige : 791 + 792
    g_re_pertes         VARCHAR2(40) := '^(679|6921|6922)[0-9]*$';  -- 679 (SCB) + 6921/6922 PCEC standard
    -- Conserves pour granularite si jamais SCB ventile un jour
    g_re_pertes_couv    VARCHAR2(40) := '^6921[0-9]*$';
    g_re_pertes_noncouv VARCHAR2(40) := '^6922[0-9]*$';

    --==========================================================================
    -- Helpers d'affichage
    --==========================================================================
    v_sep   CONSTANT VARCHAR2(120) := RPAD('=',120,'=');
    v_sub   CONSTANT VARCHAR2(120) := RPAD('-',120,'-');

    PROCEDURE p(t VARCHAR2) IS
    BEGIN
        IF t IS NULL THEN DBMS_OUTPUT.PUT_LINE(' '); RETURN; END IF;
        FOR i IN 0 .. CEIL(LENGTH(t)/250)-1 LOOP
            DBMS_OUTPUT.PUT_LINE(SUBSTR(t, i*250+1, 250));
        END LOOP;
    END;

    PROCEDURE section(c VARCHAR2, t VARCHAR2) IS
    BEGIN p(' '); p(v_sep); p('SECTION '||c||' : '||t); p(v_sep); END;

    PROCEDURE sub(t VARCHAR2) IS
    BEGIN p(' '); p(v_sub); p('>> '||t); p(v_sub); END;

    FUNCTION fmt_n(n NUMBER) RETURN VARCHAR2 IS
    BEGIN RETURN LPAD(NVL(TO_CHAR(n,'FM999G999G999G999G990D00'),'.'),22); END;

    FUNCTION fmt_p(n NUMBER) RETURN VARCHAR2 IS  -- pourcentage
    BEGIN RETURN LPAD(NVL(TO_CHAR(n,'FM990D00')||'%','.'),8); END;

    -- Classification BEAC d'un DPD
    FUNCTION classify_dpd(p_dpd NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_dpd IS NULL OR p_dpd < g_dpd_wach  THEN RETURN 'NORM';
        ELSIF p_dpd < g_dpd_sub                 THEN RETURN 'WACH';
        ELSIF p_dpd < g_dpd_doubt               THEN RETURN 'SUBSTANDARD';
        ELSIF p_dpd < g_dpd_loss                THEN RETURN 'DOUBTFUL';
        ELSE                                         RETURN 'LOSS';
        END IF;
    END;

BEGIN
    BEGIN DBMS_OUTPUT.ENABLE(NULL); EXCEPTION WHEN OTHERS THEN NULL; END;

    p(v_sep);
    p('AUDIT FLEXCUBE MODULE CL - PROVISIONS CREDITS - PHASE 2');
    p('Date execution    : '||TO_CHAR(SYSDATE,'DD-MON-YYYY HH24:MI:SS'));
    p('Date evaluation   : '||TO_CHAR(g_ref_date,'DD-MON-YYYY'));
    p('Schema            : '||SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
    p('Seuils DPD (BEAC) : WACH>='||g_dpd_wach||'  SUB>='||g_dpd_sub
                          ||'  DOUBT>='||g_dpd_doubt||'  LOSS>='||g_dpd_loss);
    p(v_sep);

    --==========================================================================
    -- SECTION B : ENCOURS - CARTOGRAPHIE GLOBALE
    --==========================================================================
    -- Encours capital, interets, penalites par contrat actif a la date de
    -- reference. Distinction :
    --   * capital restant du   = sum(PRINCIPAL) non echu OU echu impaye
    --   * capital echu impaye  = sum(PRINCIPAL) echu - regle - remis
    --   * interets non payes   = sum(MAIN_INT) echu - regle - remis
    --   * penalites non payees = sum(ODIN+ODPR+INT_ODU_*) echu - regle - remis
    --==========================================================================
    section('B','ENCOURS ET CARTOGRAPHIE GLOBALE A '||TO_CHAR(g_ref_date,'DD-MON-YYYY'));

    sub('B.1  Vue agregee par categorie / produit (contrats actifs)');
    BEGIN
        p(RPAD('CATEGORIE',16)||RPAD('PRODUIT',8)||LPAD('NB',7)
          ||LPAD('FINANCE',22)||LPAD('CAPITAL_RESTE',22)
          ||LPAD('CAP_ECHU_IMPAYE',22)||LPAD('INT_IMPAYE',22));
        FOR r IN (
            SELECT m.product_category, m.product_code,
                   COUNT(DISTINCT m.account_number)                          nb,
                   SUM(m.amount_disbursed)                                   tot_fin,
                   SUM(NVL(reste_pri.r,0))                                   cap_reste,
                   SUM(NVL(echu_pri.r,0))                                    cap_echu,
                   SUM(NVL(echu_int.r,0))                                    int_echu
              FROM cltb_account_apps_master m
              LEFT JOIN ( SELECT account_number,
                                 SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                            FROM cltb_account_schedules
                           WHERE component_name='PRINCIPAL'
                           GROUP BY account_number ) reste_pri
                ON reste_pri.account_number = m.account_number
              LEFT JOIN ( SELECT account_number,
                                 SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                            FROM cltb_account_schedules
                           WHERE component_name='PRINCIPAL'
                             AND schedule_due_date <= g_ref_date
                           GROUP BY account_number ) echu_pri
                ON echu_pri.account_number = m.account_number
              LEFT JOIN ( SELECT account_number,
                                 SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                            FROM cltb_account_schedules
                           WHERE component_name IN ('MAIN_INT','TVA_MAININT')
                             AND schedule_due_date <= g_ref_date
                           GROUP BY account_number ) echu_int
                ON echu_int.account_number = m.account_number
             WHERE m.account_status = 'A'
             GROUP BY m.product_category, m.product_code
             ORDER BY m.product_category, m.product_code)
        LOOP
            p(RPAD(NVL(r.product_category,'?'),16)||RPAD(r.product_code,8)
              ||LPAD(r.nb,7)||fmt_n(r.tot_fin)
              ||fmt_n(r.cap_reste)||fmt_n(r.cap_echu)||fmt_n(r.int_echu));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[B.1 err] '||SQLERRM); END;

    sub('B.2  Vue globale par account_status');
    BEGIN
        FOR r IN (
            SELECT m.account_status, COUNT(*) nb,
                   SUM(m.amount_financed) tot_fin,
                   SUM(m.amount_disbursed) tot_dec
              FROM cltb_account_apps_master m
             GROUP BY m.account_status ORDER BY 2 DESC)
        LOOP
            p('   status='||RPAD(NVL(r.account_status,'?'),4)
              ||' nb='||LPAD(r.nb,6)
              ||' finance='||fmt_n(r.tot_fin)
              ||' decaisse='||fmt_n(r.tot_dec));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[B.2 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION C : CLASSIFICATION DPD - APPLICATION SEUILS BEAC
    --==========================================================================
    -- Calcul du DPD a la date de reference :
    --   DPD = g_ref_date - MIN(schedule_due_date) pour les schedules dont
    --   amount_due - amount_settled - amount_waived > 0 et due_date <= g_ref_date
    -- Classement applique selon les seuils declares dans la section A.
    --==========================================================================
    section('C','CLASSIFICATION DPD - SEUILS BEAC');

    sub('C.1  Distribution des contrats actifs par classe BEAC');
    BEGIN
        FOR r IN (
            WITH dpd AS (
                SELECT s.account_number,
                       MAX(g_ref_date - s.schedule_due_date) max_dpd
                  FROM cltb_account_schedules s
                  JOIN cltb_account_apps_master m ON m.account_number = s.account_number
                 WHERE m.account_status='A'
                   AND s.schedule_due_date <= g_ref_date
                   AND NVL(s.amount_due,0)-NVL(s.amount_settled,0)-NVL(s.amount_waived,0) > 0
                 GROUP BY s.account_number
            ),
            cls AS (
                SELECT m.account_number,
                       NVL(dpd.max_dpd, 0)                  dpd_val,
                       classify_dpd(NVL(dpd.max_dpd,0))     cls,
                       NVL(reste_pri.r,0)                   cap_reste
                  FROM cltb_account_apps_master m
                  LEFT JOIN dpd ON dpd.account_number = m.account_number
                  LEFT JOIN ( SELECT account_number,
                                     SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                                FROM cltb_account_schedules
                               WHERE component_name='PRINCIPAL'
                               GROUP BY account_number ) reste_pri
                    ON reste_pri.account_number = m.account_number
                 WHERE m.account_status='A'
            )
            SELECT cls, COUNT(*) nb, SUM(cap_reste) encours,
                   MIN(dpd_val) dpd_min, MAX(dpd_val) dpd_max
              FROM cls
             GROUP BY cls
             ORDER BY DECODE(cls,'NORM',1,'WACH',2,'SUBSTANDARD',3,'DOUBTFUL',4,'LOSS',5,9))
        LOOP
            p('   '||RPAD(r.cls,12)||' nb='||LPAD(r.nb,6)
              ||' encours='||fmt_n(r.encours)
              ||' dpd_min='||LPAD(r.dpd_min,5)
              ||' dpd_max='||LPAD(r.dpd_max,5));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[C.1 err] '||SQLERRM); END;

    sub('C.2  Top '||g_top_n||' contrats DPD > '||g_dpd_sub||' j (SUB / DOUBT / LOSS)');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.product_code, m.product_category,
                       m.primary_applicant_name nom,
                       m.amount_disbursed,
                       dpd.max_dpd,
                       classify_dpd(dpd.max_dpd) cls,
                       reste_pri.r capital_reste,
                       echu.r echu_impaye
                  FROM cltb_account_apps_master m
                  JOIN ( SELECT account_number, MAX(g_ref_date - schedule_due_date) max_dpd
                           FROM cltb_account_schedules
                          WHERE schedule_due_date <= g_ref_date
                            AND NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0) > 0
                          GROUP BY account_number ) dpd
                    ON dpd.account_number = m.account_number
                  LEFT JOIN ( SELECT account_number,
                                     SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                                FROM cltb_account_schedules
                               WHERE component_name='PRINCIPAL'
                               GROUP BY account_number ) reste_pri
                    ON reste_pri.account_number = m.account_number
                  LEFT JOIN ( SELECT account_number,
                                     SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                                FROM cltb_account_schedules
                               WHERE schedule_due_date <= g_ref_date
                                 AND NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)>0
                               GROUP BY account_number ) echu
                    ON echu.account_number = m.account_number
                 WHERE m.account_status='A'
                   AND dpd.max_dpd >= g_dpd_sub
                 ORDER BY dpd.max_dpd DESC, reste_pri.r DESC NULLS LAST
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.account_number,22)
              ||' '||RPAD(NVL(r.nom,'?'),30)
              ||' prod='||RPAD(r.product_code,6)
              ||' DPD='||LPAD(r.max_dpd,5)
              ||' cls='||RPAD(r.cls,12)
              ||' encours='||fmt_n(r.capital_reste)
              ||' echu='||fmt_n(r.echu_impaye));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[C.2 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION D : RESERVES D'INTERETS (CLASSE 9 - HORS BILAN)
    --==========================================================================
    -- Module CL en SCB : passage en SACR (Suspended Accrual)
    --   tag MAIN_INT_SACR : DR 985xxxxxx (interets reserves sur creance en SO)
    --                       CR 997xxxxxx (interets et commissions reservees)
    -- Audit :
    --   D.1 Solde des comptes 985 et 997 (doit etre symetrique D=C)
    --   D.2 Cumul SACR par contrat
    --   D.3 Coherence : un contrat avec SACR ne devrait plus generer
    --       MAIN_INT_ACCR au compte 712xxx (ou alors c'est reverse via RACR_REAL)
    --   D.4 Reintegrations (_RACR_REAL) : volume et detection des reversal
    --       qui ne sont pas accompagnes d'un realisme (paiement effectif)
    --==========================================================================
    section('D','RESERVES INTERETS (HORS BILAN - CLASSE 9)');

    sub('D.1  Soldes cumules des comptes 985xxx (DR) et 997xxx (CR)');
    BEGIN
        FOR r IN (
            SELECT a.ac_no, MAX(s.ac_gl_desc) gl_desc,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount
                            ELSE -a.lcy_amount END) solde
              FROM actb_history a
              LEFT JOIN sttb_account s ON s.ac_gl_no = a.ac_no
             WHERE (REGEXP_LIKE(a.ac_no, g_re_int_reserve_dr)
                 OR REGEXP_LIKE(a.ac_no, g_re_int_reserve_cr))
               AND a.trn_dt <= g_ref_date
             GROUP BY a.ac_no
             ORDER BY a.ac_no)
        LOOP
            p('   '||RPAD(r.ac_no,15)||' '||RPAD(NVL(r.gl_desc,'?'),45)
              ||' D='||fmt_n(r.tot_dr)||' C='||fmt_n(r.tot_cr)
              ||' solde='||fmt_n(r.solde));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[D.1 err] '||SQLERRM); END;

    sub('D.2  Top '||g_top_n||' contrats avec cumul SACR (MAIN_INT_SACR)');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT a.related_account, m.product_code, m.primary_applicant_name nom,
                       SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_sacr_dr,
                       SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_sacr_cr,
                       MIN(a.trn_dt) first_sacr, MAX(a.trn_dt) last_sacr,
                       COUNT(*) nb
                  FROM actb_history a
                  LEFT JOIN cltb_account_apps_master m
                    ON m.account_number = a.related_account
                 WHERE a.module='CL'
                   AND a.amount_tag = 'MAIN_INT_SACR'
                   AND a.trn_dt <= g_ref_date
                 GROUP BY a.related_account, m.product_code, m.primary_applicant_name
                 ORDER BY 4 DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.related_account,22)
              ||' prod='||RPAD(NVL(r.product_code,'?'),6)
              ||' '||RPAD(NVL(r.nom,'?'),25)
              ||' SACR_DR='||fmt_n(r.tot_sacr_dr)
              ||' SACR_CR='||fmt_n(r.tot_sacr_cr)
              ||' nb='||LPAD(r.nb,5)
              ||' periode='||TO_CHAR(r.first_sacr,'DD-MON-YY')
              ||'->'||TO_CHAR(r.last_sacr,'DD-MON-YY'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[D.2 err] '||SQLERRM); END;

    sub('D.3  Incoherence : contrat en SACR avec accruals CL recents au compte de produits');
    -- Un contrat ayant des MAIN_INT_SACR (reserves d'interets) devrait avoir
    -- ses accruals MAIN_INT_ACCR au compte de produits 712xxx STOPPES.
    -- On detecte tout MAIN_INT_ACCR posterieur au dernier SACR.
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT sacr.related_account, MAX(sacr.last_sacr) last_sacr,
                       SUM(acc.lcy_amount) accr_apres_sacr,
                       COUNT(acc.lcy_amount) nb_accr_apres
                  FROM ( SELECT related_account, MAX(trn_dt) last_sacr
                           FROM actb_history
                          WHERE module='CL' AND amount_tag='MAIN_INT_SACR'
                            AND trn_dt <= g_ref_date
                          GROUP BY related_account ) sacr
                  JOIN actb_history acc
                    ON acc.related_account = sacr.related_account
                   AND acc.module='CL'
                   AND acc.amount_tag='MAIN_INT_ACCR'
                   AND acc.drcr_ind='C'
                   AND REGEXP_LIKE(acc.ac_no, g_re_revenue_int)
                   AND acc.trn_dt > sacr.last_sacr
                   AND acc.trn_dt <= g_ref_date
                 GROUP BY sacr.related_account
                 ORDER BY 3 DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.related_account,22)
              ||' dernier_SACR='||TO_CHAR(r.last_sacr,'DD-MON-YY')
              ||' accruals_apres='||fmt_n(r.accr_apres_sacr)
              ||' nb='||r.nb_accr_apres);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[D.3 err] '||SQLERRM); END;

    sub('D.4  Reintegrations MAIN_INT_RACR_REAL (reversal accrual) sans paiement liquidation associe');
    -- Quand un crédit déclassé est repaye, on peut faire MAIN_INT_RACR_REAL
    -- pour reintegrer les interets reserves au compte de resultat. Si on
    -- voit un RACR_REAL sans MAIN_INT_LIQD a la meme periode, c'est suspect.
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT a.related_account, a.trn_dt, a.lcy_amount, a.drcr_ind,
                       (SELECT NVL(SUM(b.lcy_amount),0) FROM actb_history b
                         WHERE b.related_account = a.related_account
                           AND b.amount_tag = 'MAIN_INT_LIQD'
                           AND b.drcr_ind='D'
                           AND b.trn_dt BETWEEN a.trn_dt-7 AND a.trn_dt+7) liqd_proche
                  FROM actb_history a
                 WHERE a.module='CL'
                   AND a.amount_tag = 'MAIN_INT_RACR_REAL'
                   AND a.drcr_ind='D'
                   AND a.trn_dt <= g_ref_date
                 ORDER BY a.trn_dt DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.related_account,22)
              ||' '||TO_CHAR(r.trn_dt,'DD-MON-YY')
              ||' montant='||fmt_n(r.lcy_amount)
              ||' liqd_+/-7j='||fmt_n(r.liqd_proche)
              ||CASE WHEN r.liqd_proche=0 THEN ' *** SANS LIQD ***' END);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[D.4 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION E : RECLASSEMENTS ENTRE STATUTS
    --==========================================================================
    -- Les tags _NORM_REAL, _WACH_REAL, _SUB_REAL etc. realisent le transfert
    -- comptable entre comptes de creance par statut :
    --   PRINCIPAL_NORM_REAL  capital reclasse vers SAINS
    --   MAIN_INT_NORM_REAL   interets rattaches reclasses vers SAINS
    --   MAIN_INT_WACH_REAL   interets rattaches reclasses vers WACH
    --   MAIN_INT_SACR        passage en suspension d'accrual
    -- Audit :
    --   E.1 Volume des reclassements
    --   E.2 Pour chaque contrat avec reclassement, DPD au moment du transfert
    --==========================================================================
    section('E','RECLASSEMENTS ENTRE STATUTS');

    sub('E.1  Volume des reclassements par tag');
    BEGIN
        FOR r IN (
            SELECT a.amount_tag,
                   COUNT(DISTINCT a.related_account) nb_contrats,
                   COUNT(*) nb_ecritures,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   MIN(a.trn_dt) date_min, MAX(a.trn_dt) date_max
              FROM actb_history a
             WHERE a.module='CL'
               AND ( a.amount_tag LIKE '%_NORM_REAL'
                  OR a.amount_tag LIKE '%_WACH_REAL'
                  OR a.amount_tag LIKE '%_SUB_REAL'
                  OR a.amount_tag LIKE '%_DOUB_REAL'
                  OR a.amount_tag LIKE '%_LOSS_REAL'
                  OR a.amount_tag = 'MAIN_INT_SACR'
                  OR a.amount_tag LIKE '%_RACR_REAL' )
               AND a.trn_dt <= g_ref_date
             GROUP BY a.amount_tag
             ORDER BY 1)
        LOOP
            p('   '||RPAD(r.amount_tag,28)
              ||' nb_contrats='||LPAD(r.nb_contrats,5)
              ||' nb_ecr='||LPAD(r.nb_ecritures,6)
              ||' montant_DR='||fmt_n(r.tot_dr)
              ||' periode='||TO_CHAR(r.date_min,'DD-MON-YY')
              ||'->'||TO_CHAR(r.date_max,'DD-MON-YY'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[E.1 err] '||SQLERRM); END;

    sub('E.2  Top '||g_top_n||' contrats : chronologie des reclassements');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT related_account, COUNT(*) nb_reclas, MAX(trn_dt) last_reclas
                  FROM actb_history
                 WHERE module='CL'
                   AND ( amount_tag LIKE '%_NORM_REAL'
                      OR amount_tag LIKE '%_WACH_REAL'
                      OR amount_tag = 'MAIN_INT_SACR' )
                   AND trn_dt <= g_ref_date
                 GROUP BY related_account
                 ORDER BY 2 DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.related_account,22)
              ||' nb_reclas='||LPAD(r.nb_reclas,4)
              ||' dernier='||TO_CHAR(r.last_reclas,'DD-MON-YY'));
            FOR e IN (
                SELECT trn_dt, amount_tag, drcr_ind, ac_no, lcy_amount
                  FROM actb_history
                 WHERE module='CL'
                   AND related_account = r.related_account
                   AND ( amount_tag LIKE '%_NORM_REAL'
                      OR amount_tag LIKE '%_WACH_REAL'
                      OR amount_tag = 'MAIN_INT_SACR' )
                 ORDER BY trn_dt, amount_tag, drcr_ind)
            LOOP
                p('       '||TO_CHAR(e.trn_dt,'DD-MON-YY')
                  ||' '||RPAD(e.amount_tag,25)
                  ||' '||e.drcr_ind
                  ||' ac='||RPAD(e.ac_no,15)
                  ||' '||fmt_n(e.lcy_amount));
            END LOOP;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[E.2 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION F : RECONCILIATION GL - ENCOURS CL
    --==========================================================================
    -- Pour chaque compte GL de creance (311xxx/321xxx/318xxx/328xxx) on
    -- compare :
    --    Solde GL          = SUM(D) - SUM(C) sur actb_history (a g_ref_date)
    --    Encours CL deduit = SUM(amount_due - amount_settled - amount_waived)
    --                         sur cltb_account_schedules cumule sur les
    --                         contrats relies a ce compte (via dr_prod_ac).
    -- Ecart > tolerance = anomalie a investiguer.
    --==========================================================================
    section('F','RECONCILIATION COMPTES GL CREDITS vs ENCOURS CL');

    sub('F.1  Soldes cumules des comptes de creances (cl.3) et rattachees');
    BEGIN
        FOR r IN (
            SELECT a.ac_no, MAX(s.ac_gl_desc) gl_desc,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE -a.lcy_amount END) solde
              FROM actb_history a
              LEFT JOIN sttb_account s ON s.ac_gl_no = a.ac_no
             WHERE a.module='CL'
               AND ( REGEXP_LIKE(a.ac_no, g_re_credit_sain)
                  OR REGEXP_LIKE(a.ac_no, g_re_credit_irreg)
                  OR REGEXP_LIKE(a.ac_no, g_re_credit_doubt)
                  OR REGEXP_LIKE(a.ac_no, g_re_creanc_ratt) )
               AND a.trn_dt <= g_ref_date
             GROUP BY a.ac_no
             ORDER BY a.ac_no)
        LOOP
            p('   '||RPAD(r.ac_no,15)||' '||RPAD(NVL(r.gl_desc,'?'),45)
              ||' D='||fmt_n(r.tot_dr)
              ||' C='||fmt_n(r.tot_cr)
              ||' solde='||fmt_n(r.solde));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[F.1 err] '||SQLERRM); END;

    sub('F.2  Reconciliation : solde GL "credit sain" vs sum(encours CL)');
    -- On rattache chaque contrat a son GL de prod via dr_prod_ac (le GL
    -- credite a la mise en place du credit) - voir phase 1 dossier 8.
    BEGIN
        FOR r IN (
            SELECT gl.ac_no, MAX(s.ac_gl_desc) gl_desc,
                   gl.solde_gl,
                   NVL(enc.encours,0) encours_cl,
                   gl.solde_gl - NVL(enc.encours,0) ecart
              FROM ( SELECT ac_no,
                            SUM(CASE WHEN drcr_ind='D' THEN lcy_amount
                                     ELSE -lcy_amount END) solde_gl
                       FROM actb_history
                      WHERE module='CL'
                        AND REGEXP_LIKE(ac_no, g_re_credit_sain)
                        AND trn_dt <= g_ref_date
                      GROUP BY ac_no ) gl
              LEFT JOIN ( SELECT m.dr_prod_ac, SUM(rest.r) encours
                            FROM cltb_account_apps_master m
                            JOIN ( SELECT account_number,
                                          SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                                     FROM cltb_account_schedules
                                    WHERE component_name='PRINCIPAL'
                                    GROUP BY account_number ) rest
                              ON rest.account_number = m.account_number
                           WHERE m.account_status='A'
                           GROUP BY m.dr_prod_ac ) enc
                ON enc.dr_prod_ac = gl.ac_no
              LEFT JOIN sttb_account s ON s.ac_gl_no = gl.ac_no
             WHERE ABS(gl.solde_gl - NVL(enc.encours,0)) > g_tol_recon
             ORDER BY ABS(gl.solde_gl - NVL(enc.encours,0)) DESC)
        LOOP
            p('   '||RPAD(r.ac_no,15)||' '||RPAD(NVL(r.gl_desc,'?'),35)
              ||' GL='||fmt_n(r.solde_gl)
              ||' CL='||fmt_n(r.encours_cl)
              ||' ecart='||fmt_n(r.ecart));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[F.2 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION G : CYCLE DE VIE DES PROVISIONS - 3 ETAPES (PCEC COBAC + SCB)
    --==========================================================================
    -- Logique PCEC COBAC R-98/01, adaptee a la pratique observee SCB Cameroun :
    --   ETAPE 1 - DOTATION (creation/augmentation provision)
    --     DR 691 Dotations aux provisions  CR 39x Provisions creances depreciees
    --     (Theoriquement 6913 specifique clientele - SCB agrege en 691)
    --   ETAPE 2A - AJUSTEMENT EN HAUSSE = meme schema que dotation, pour le delta
    --   ETAPE 2B - AJUSTEMENT EN BAISSE / REPRISE
    --     DR 39x Provisions  CR 791 Reprises de provisions
    --     (Theoriquement 7913 - SCB agrege en 791)
    --   ETAPE 3A - REMBOURSEMENT INTEGRAL : reprise totale (idem 2B)
    --   ETAPE 3B - RENTREE SUR CREANCE ABANDONNEE (apres passage en perte)
    --     DR 5xx Tresorerie  CR 792 Rentrees sur creances abandonnees
    --   ETAPE 3C - PASSAGE EN PERTE  (specificite SCB : pas de distinction
    --              couvert / non couvert ; tout passe en 679 et non 6921/6922)
    --     DR 679 Pertes sur ops clientele  CR 34x Creances en souffrance
    --     DR 39x Provisions                 CR 791 Reprises (extournes le stock)
    --
    -- Pattern de decouverte (executee manuellement) confirme :
    --   691 nb=154   791 nb=12    792 nb=2    679 nb=31
    --   985 nb=870   997 nb=870
    --   6921, 6922, 6913, 7913 : ABSENTS du plan effectif
    --
    -- Constat phase 1 : aucun tag du module CL ne porte ces ecritures - les
    -- dotations / reprises / pertes sont passees par un AUTRE module (DE/GL
    -- manuel ou batch externe).
    --==========================================================================
    section('G','CYCLE DE VIE DES PROVISIONS (PCEC COBAC adapte pratique SCB)');

    sub('G.1  Inventaire des comptes-cles du cycle (34 / 39 / 679 / 691 / 791 / 792)');
    BEGIN
        FOR r IN (
            SELECT a.ac_no, MAX(s.ac_gl_desc) gl_desc,
                   CASE
                     WHEN REGEXP_LIKE(a.ac_no, g_re_dotations)    THEN '1-DOTATION 691'
                     WHEN REGEXP_LIKE(a.ac_no, '^792[0-9]*$')     THEN '2-RENTREE  792'
                     WHEN REGEXP_LIKE(a.ac_no, '^791[0-9]*$')     THEN '2-REPRISE  791'
                     WHEN REGEXP_LIKE(a.ac_no, g_re_pertes)       THEN '3-PERTE    679'
                     WHEN REGEXP_LIKE(a.ac_no, g_re_provisions)   THEN '0-PROV     39x'
                     WHEN REGEXP_LIKE(a.ac_no, g_re_creanc_souff) THEN '0-SOUFFR   34x'
                   END type_compte,
                   COUNT(*) nb,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE -a.lcy_amount END) solde
              FROM actb_history a
              LEFT JOIN sttb_account s ON s.ac_gl_no = a.ac_no
             WHERE ( REGEXP_LIKE(a.ac_no, g_re_creanc_souff)
                  OR REGEXP_LIKE(a.ac_no, g_re_provisions)
                  OR REGEXP_LIKE(a.ac_no, g_re_dotations)
                  OR REGEXP_LIKE(a.ac_no, g_re_pertes)
                  OR REGEXP_LIKE(a.ac_no, g_re_reprises) )
               AND a.trn_dt <= g_ref_date
             GROUP BY a.ac_no
             ORDER BY type_compte, a.ac_no)
        LOOP
            p('   '||RPAD(r.type_compte,18)||' '||RPAD(r.ac_no,15)
              ||' '||RPAD(NVL(r.gl_desc,'?'),40)
              ||' nb='||LPAD(r.nb,6)
              ||' D='||fmt_n(r.tot_dr)
              ||' C='||fmt_n(r.tot_cr)
              ||' solde='||fmt_n(r.solde));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G.1 err] '||SQLERRM); END;

    sub('G.2  Modules createurs des ecritures provisions (constat : hors CL ?)');
    BEGIN
        FOR r IN (
            SELECT a.module,
                   CASE
                     WHEN REGEXP_LIKE(a.ac_no, g_re_dotations)    THEN '1-DOTATION 691'
                     WHEN REGEXP_LIKE(a.ac_no, '^792[0-9]*$')     THEN '2-RENTREE  792'
                     WHEN REGEXP_LIKE(a.ac_no, '^791[0-9]*$')     THEN '2-REPRISE  791'
                     WHEN REGEXP_LIKE(a.ac_no, g_re_pertes)       THEN '3-PERTE    679'
                     WHEN REGEXP_LIKE(a.ac_no, g_re_provisions)   THEN '0-PROV     39x'
                     WHEN REGEXP_LIKE(a.ac_no, g_re_creanc_souff) THEN '0-SOUFFR   34x'
                   END type_compte,
                   COUNT(*) nb,
                   COUNT(DISTINCT a.related_account) nb_contrats,
                   SUM(CASE WHEN a.drcr_ind='D' THEN a.lcy_amount ELSE 0 END) tot_dr,
                   SUM(CASE WHEN a.drcr_ind='C' THEN a.lcy_amount ELSE 0 END) tot_cr,
                   MIN(a.trn_dt) date_min, MAX(a.trn_dt) date_max
              FROM actb_history a
             WHERE ( REGEXP_LIKE(a.ac_no, g_re_creanc_souff)
                  OR REGEXP_LIKE(a.ac_no, g_re_provisions)
                  OR REGEXP_LIKE(a.ac_no, g_re_dotations)
                  OR REGEXP_LIKE(a.ac_no, g_re_pertes)
                  OR REGEXP_LIKE(a.ac_no, g_re_reprises) )
               AND a.trn_dt <= g_ref_date
             GROUP BY a.module,
                      CASE
                        WHEN REGEXP_LIKE(a.ac_no, g_re_dotations)    THEN '1-DOTATION 691'
                        WHEN REGEXP_LIKE(a.ac_no, '^792[0-9]*$')     THEN '2-RENTREE  792'
                        WHEN REGEXP_LIKE(a.ac_no, '^791[0-9]*$')     THEN '2-REPRISE  791'
                        WHEN REGEXP_LIKE(a.ac_no, g_re_pertes)       THEN '3-PERTE    679'
                        WHEN REGEXP_LIKE(a.ac_no, g_re_provisions)   THEN '0-PROV     39x'
                        WHEN REGEXP_LIKE(a.ac_no, g_re_creanc_souff) THEN '0-SOUFFR   34x'
                      END
             ORDER BY a.module, type_compte)
        LOOP
            p('   module='||RPAD(r.module,5)||' '||RPAD(r.type_compte,18)
              ||' nb_ecr='||LPAD(r.nb,6)
              ||' nb_contrats='||LPAD(r.nb_contrats,5)
              ||' D='||fmt_n(r.tot_dr)||' C='||fmt_n(r.tot_cr)
              ||' '||TO_CHAR(r.date_min,'DD-MON-YY')||'->'||TO_CHAR(r.date_max,'DD-MON-YY'));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G.2 err] '||SQLERRM); END;

    sub('G.3  ETAPE 1 - DOTATIONS (DR 691 / CR 39x) - flux annuel');
    -- Par exercice (financial_cycle), volume des dotations effectives.
    BEGIN
        FOR r IN (
            SELECT a.financial_cycle,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_dotations) AND a.drcr_ind='D'
                            THEN a.lcy_amount ELSE 0 END) dot_charge,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_provisions) AND a.drcr_ind='C'
                            THEN a.lcy_amount ELSE 0 END) dot_provision,
                   COUNT(DISTINCT CASE WHEN REGEXP_LIKE(a.ac_no,g_re_dotations)
                                       THEN a.trn_ref_no END) nb_ecr_dotation
              FROM actb_history a
             WHERE a.trn_dt <= g_ref_date
               AND ( REGEXP_LIKE(a.ac_no, g_re_dotations)
                  OR REGEXP_LIKE(a.ac_no, g_re_provisions) )
             GROUP BY a.financial_cycle
             ORDER BY a.financial_cycle)
        LOOP
            p('   cycle='||RPAD(r.financial_cycle,8)
              ||' charge_691='||fmt_n(r.dot_charge)
              ||' credit_39='||fmt_n(r.dot_provision)
              ||' ecart='||fmt_n(r.dot_charge - r.dot_provision)
              ||' nb_ecr='||r.nb_ecr_dotation);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G.3 err] '||SQLERRM); END;

    sub('G.4  ETAPE 2 - REPRISES (DR 39x / CR 791) et RENTREES (CR 792) - flux annuel');
    BEGIN
        FOR r IN (
            SELECT a.financial_cycle,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_provisions) AND a.drcr_ind='D'
                            THEN a.lcy_amount ELSE 0 END) rep_provision,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,'^791[0-9]*$') AND a.drcr_ind='C'
                            THEN a.lcy_amount ELSE 0 END) rep_791,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,'^792[0-9]*$') AND a.drcr_ind='C'
                            THEN a.lcy_amount ELSE 0 END) rent_792,
                   COUNT(DISTINCT CASE WHEN REGEXP_LIKE(a.ac_no,g_re_reprises)
                                       THEN a.trn_ref_no END) nb_ecr
              FROM actb_history a
             WHERE a.trn_dt <= g_ref_date
               AND ( REGEXP_LIKE(a.ac_no, g_re_reprises)
                  OR REGEXP_LIKE(a.ac_no, g_re_provisions) )
             GROUP BY a.financial_cycle
             ORDER BY a.financial_cycle)
        LOOP
            p('   cycle='||RPAD(r.financial_cycle,8)
              ||' debit_39='||fmt_n(r.rep_provision)
              ||' reprise_791='||fmt_n(r.rep_791)
              ||' rentree_792='||fmt_n(r.rent_792)
              ||' nb_ecr='||r.nb_ecr);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G.4 err] '||SQLERRM); END;

    sub('G.5  ETAPE 3 - PASSAGE EN PERTE (DR 679 / CR 34x) - flux annuel');
    -- Specificite SCB : pas de distinction couvert/non couvert. Tout passe en 679.
    -- On suit en plus toute autre ecriture 6921/6922 par defense (en theorie absente).
    BEGIN
        FOR r IN (
            SELECT a.financial_cycle,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,'^679[0-9]*$') AND a.drcr_ind='D'
                            THEN a.lcy_amount ELSE 0 END) perte_679,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,'^6921[0-9]*$') AND a.drcr_ind='D'
                            THEN a.lcy_amount ELSE 0 END) perte_couv,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,'^6922[0-9]*$') AND a.drcr_ind='D'
                            THEN a.lcy_amount ELSE 0 END) perte_noncouv,
                   SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_creanc_souff) AND a.drcr_ind='C'
                            THEN a.lcy_amount ELSE 0 END) sortie_34,
                   COUNT(DISTINCT CASE WHEN REGEXP_LIKE(a.ac_no,g_re_pertes)
                                       THEN a.related_account END) nb_dossiers
              FROM actb_history a
             WHERE a.trn_dt <= g_ref_date
               AND ( REGEXP_LIKE(a.ac_no, g_re_pertes)
                  OR REGEXP_LIKE(a.ac_no, g_re_creanc_souff) )
             GROUP BY a.financial_cycle
             ORDER BY a.financial_cycle)
        LOOP
            p('   cycle='||RPAD(r.financial_cycle,8)
              ||' perte_679='||fmt_n(r.perte_679)
              ||' (6921='||fmt_n(r.perte_couv)
              ||' 6922='||fmt_n(r.perte_noncouv)||')'
              ||' sortie_34='||fmt_n(r.sortie_34)
              ||' nb_dossiers='||r.nb_dossiers);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G.5 err] '||SQLERRM); END;

    sub('G.6  CYCLE COMPLET PAR DOSSIER : dotation / reprise / perte / souffrance');
    -- Vue contrat par contrat de l'historique des mouvements de provisions.
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT a.related_account,
                       SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_dotations) AND a.drcr_ind='D'
                                THEN a.lcy_amount ELSE 0 END) cum_dotation,
                       SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_reprises) AND a.drcr_ind='C'
                                THEN a.lcy_amount ELSE 0 END) cum_reprise,
                       SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_pertes) AND a.drcr_ind='D'
                                THEN a.lcy_amount ELSE 0 END) cum_perte,
                       SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_creanc_souff) AND a.drcr_ind='D'
                                THEN a.lcy_amount
                                WHEN REGEXP_LIKE(a.ac_no,g_re_creanc_souff) AND a.drcr_ind='C'
                                THEN -a.lcy_amount ELSE 0 END) solde_34,
                       SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_provisions) AND a.drcr_ind='C'
                                THEN a.lcy_amount
                                WHEN REGEXP_LIKE(a.ac_no,g_re_provisions) AND a.drcr_ind='D'
                                THEN -a.lcy_amount ELSE 0 END) solde_39,
                       MIN(a.trn_dt) date_min, MAX(a.trn_dt) date_max
                  FROM actb_history a
                 WHERE a.related_account IS NOT NULL
                   AND a.trn_dt <= g_ref_date
                   AND ( REGEXP_LIKE(a.ac_no, g_re_creanc_souff)
                      OR REGEXP_LIKE(a.ac_no, g_re_provisions)
                      OR REGEXP_LIKE(a.ac_no, g_re_dotations)
                      OR REGEXP_LIKE(a.ac_no, g_re_pertes)
                      OR REGEXP_LIKE(a.ac_no, g_re_reprises) )
                 GROUP BY a.related_account
                 ORDER BY ABS(SUM(CASE WHEN REGEXP_LIKE(a.ac_no,g_re_provisions) AND a.drcr_ind='C'
                                       THEN a.lcy_amount
                                       WHEN REGEXP_LIKE(a.ac_no,g_re_provisions) AND a.drcr_ind='D'
                                       THEN -a.lcy_amount ELSE 0 END)) DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.related_account,22)
              ||' dot_691='||fmt_n(r.cum_dotation)
              ||' rep_791_792='||fmt_n(r.cum_reprise)
              ||' perte_679='||fmt_n(r.cum_perte)
              ||' solde_34='||fmt_n(r.solde_34)
              ||' solde_39='||fmt_n(r.solde_39));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G.6 err] '||SQLERRM); END;

    sub('G.7  COHERENCE : pour chaque contrat avec mouvement provision, statut CL associe');
    -- On rapproche : contrats avec provision detectee vs leur situation CL :
    --   - account_status, DPD courant, encours
    --   - presence/absence de MAIN_INT_SACR (reserve interets)
    -- Permet de detecter :
    --   * provisions sur contrats deja liquides (incoherence)
    --   * contrats DPD>180 SANS provision (sous-provisionnement potentiel)
    --   * contrats provisionnes mais sans SACR (incoherence interets)
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.product_code, m.account_status,
                       NVL(prov.cum_dot,0) - NVL(prov.cum_rep,0) prov_nette,
                       NVL(dpd.max_dpd,0) dpd,
                       NVL(sacr.tot_sacr,0) tot_sacr,
                       NVL(reste.r,0) capital_reste
                  FROM cltb_account_apps_master m
                  LEFT JOIN ( SELECT related_account,
                                     SUM(CASE WHEN REGEXP_LIKE(ac_no,g_re_dotations) AND drcr_ind='D'
                                              THEN lcy_amount ELSE 0 END) cum_dot,
                                     SUM(CASE WHEN REGEXP_LIKE(ac_no,g_re_reprises) AND drcr_ind='C'
                                              THEN lcy_amount ELSE 0 END) cum_rep
                                FROM actb_history WHERE trn_dt <= g_ref_date
                               GROUP BY related_account ) prov
                    ON prov.related_account = m.account_number
                  LEFT JOIN ( SELECT account_number, MAX(g_ref_date - schedule_due_date) max_dpd
                                FROM cltb_account_schedules
                               WHERE schedule_due_date <= g_ref_date
                                 AND NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0) > 0
                               GROUP BY account_number ) dpd
                    ON dpd.account_number = m.account_number
                  LEFT JOIN ( SELECT related_account,
                                     SUM(CASE WHEN drcr_ind='D' THEN lcy_amount ELSE 0 END) tot_sacr
                                FROM actb_history
                               WHERE module='CL' AND amount_tag='MAIN_INT_SACR'
                                 AND trn_dt <= g_ref_date
                               GROUP BY related_account ) sacr
                    ON sacr.related_account = m.account_number
                  LEFT JOIN ( SELECT account_number,
                                     SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                                FROM cltb_account_schedules
                               WHERE component_name='PRINCIPAL'
                               GROUP BY account_number ) reste
                    ON reste.account_number = m.account_number
                 WHERE ( NVL(prov.cum_dot,0)+NVL(prov.cum_rep,0) > 0
                      OR (NVL(dpd.max_dpd,0) >= g_dpd_doubt AND m.account_status='A') )
                 ORDER BY GREATEST(NVL(prov.cum_dot,0), NVL(prov.cum_rep,0)) DESC,
                          NVL(dpd.max_dpd,0) DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.account_number,22)
              ||' status='||r.account_status
              ||' DPD='||LPAD(r.dpd,4)||' cls='||RPAD(classify_dpd(r.dpd),11)
              ||' encours='||fmt_n(r.capital_reste)
              ||' prov_nette='||fmt_n(r.prov_nette)
              ||' SACR='||fmt_n(r.tot_sacr));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G.7 err] '||SQLERRM); END;

    sub('G.8  ALERTE - Contrats classes DOUBT/LOSS (DPD>='||g_dpd_doubt||') SANS aucune provision');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.product_code, m.primary_applicant_name nom,
                       dpd.max_dpd,
                       reste.r capital_reste
                  FROM cltb_account_apps_master m
                  JOIN ( SELECT account_number, MAX(g_ref_date - schedule_due_date) max_dpd
                           FROM cltb_account_schedules
                          WHERE schedule_due_date <= g_ref_date
                            AND NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0) > 0
                          GROUP BY account_number ) dpd
                    ON dpd.account_number = m.account_number
                  LEFT JOIN ( SELECT account_number,
                                     SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)) r
                                FROM cltb_account_schedules
                               WHERE component_name='PRINCIPAL'
                               GROUP BY account_number ) reste
                    ON reste.account_number = m.account_number
                 WHERE m.account_status='A'
                   AND dpd.max_dpd >= g_dpd_doubt
                   AND NOT EXISTS ( SELECT 1 FROM actb_history a
                                     WHERE a.related_account = m.account_number
                                       AND a.trn_dt <= g_ref_date
                                       AND ( REGEXP_LIKE(a.ac_no, g_re_provisions)
                                          OR REGEXP_LIKE(a.ac_no, g_re_dotations) ) )
                 ORDER BY reste.r DESC NULLS LAST
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.account_number,22)||' prod='||RPAD(r.product_code,6)
              ||' '||RPAD(NVL(r.nom,'?'),25)
              ||' DPD='||LPAD(r.max_dpd,5)
              ||' encours='||fmt_n(r.capital_reste)
              ||' *** AUCUNE PROVISION ***');
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[G.8 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION H : AUDIT DES TAUX UDE vs ACCRUALS EFFECTIFS
    --==========================================================================
    -- Pour un echantillon de contrats actifs, on calcule l'accrual theorique
    -- d'interets sur l'annee precedente (encours moyen * INTEREST_RATE/360 * jours)
    -- et on le compare aux MAIN_INT_ACCR effectivement passes sur la periode.
    -- Ecart relatif > g_tol_accr_pct = anomalie a verifier (taux, base de calcul,
    -- nombre de jours, capital pris en compte).
    --==========================================================================
    section('H','AUDIT TAUX UDE vs ACCRUALS EFFECTIFS');

    sub('H.1  Top '||g_top_n||' contrats : taux courant vs accruals reels (12 derniers mois)');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.product_code, m.amount_disbursed,
                       ude.rate_courant,
                       acc.tot_accr,
                       ROUND(m.amount_disbursed * NVL(ude.rate_courant,0)/100, 0) accr_estim_an,
                       acc.tot_accr - ROUND(m.amount_disbursed * NVL(ude.rate_courant,0)/100, 0) ecart
                  FROM cltb_account_apps_master m
                  LEFT JOIN ( SELECT u.account_number, u.ude_value rate_courant
                                FROM cltb_account_ude_values u
                               WHERE u.ude_id='INTEREST_RATE'
                                 AND u.effective_date = (SELECT MAX(u2.effective_date)
                                                            FROM cltb_account_ude_values u2
                                                           WHERE u2.account_number=u.account_number
                                                             AND u2.ude_id='INTEREST_RATE'
                                                             AND u2.effective_date <= g_ref_date) ) ude
                    ON ude.account_number = m.account_number
                  LEFT JOIN ( SELECT related_account,
                                     SUM(CASE WHEN drcr_ind='D' THEN lcy_amount ELSE 0 END) tot_accr
                                FROM actb_history
                               WHERE module='CL'
                                 AND amount_tag='MAIN_INT_ACCR'
                                 AND trn_dt BETWEEN ADD_MONTHS(g_ref_date,-12) AND g_ref_date
                               GROUP BY related_account ) acc
                    ON acc.related_account = m.account_number
                 WHERE m.account_status='A'
                   AND m.amount_disbursed > 0
                   AND NVL(ude.rate_courant,0) > 0
                   AND NVL(acc.tot_accr,0) > 0
                 ORDER BY ABS(NVL(acc.tot_accr,0)
                               - ROUND(m.amount_disbursed * NVL(ude.rate_courant,0)/100, 0)) DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.account_number,22)
              ||' prod='||RPAD(r.product_code,6)
              ||' decaisse='||fmt_n(r.amount_disbursed)
              ||' taux='||LPAD(r.rate_courant,6)||'%'
              ||' accr_reel='||fmt_n(r.tot_accr)
              ||' estim='||fmt_n(r.accr_estim_an)
              ||' ecart='||fmt_n(r.ecart));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[H.1 err] '||SQLERRM); END;

    sub('H.2  Anomalies de parametrage UDE : taux nul, taux extreme, valeurs incoherentes');
    BEGIN
        -- taux nul sur contrats actifs avec decaissement
        p('   * Contrats actifs avec INTEREST_RATE = 0 :');
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.product_code, m.amount_disbursed,
                       u.ude_value rate, u.effective_date
                  FROM cltb_account_apps_master m
                  JOIN cltb_account_ude_values u ON u.account_number = m.account_number
                 WHERE m.account_status='A'
                   AND m.amount_disbursed > 0
                   AND u.ude_id='INTEREST_RATE'
                   AND u.effective_date = (SELECT MAX(u2.effective_date)
                                              FROM cltb_account_ude_values u2
                                             WHERE u2.account_number=u.account_number
                                               AND u2.ude_id='INTEREST_RATE'
                                               AND u2.effective_date <= g_ref_date)
                   AND TO_NUMBER(u.ude_value) = 0
                 ORDER BY m.amount_disbursed DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('      '||RPAD(r.account_number,22)||' prod='||RPAD(r.product_code,6)
              ||' decaisse='||fmt_n(r.amount_disbursed)
              ||' rate='||r.rate||' eff='||TO_CHAR(r.effective_date,'DD-MON-YY'));
        END LOOP;

        -- taux > 25%
        p('   * Contrats avec INTEREST_RATE > 25% (taux usuraire potentiel) :');
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.product_code, u.ude_value rate
                  FROM cltb_account_apps_master m
                  JOIN cltb_account_ude_values u ON u.account_number = m.account_number
                 WHERE u.ude_id='INTEREST_RATE'
                   AND TO_NUMBER(u.ude_value) > 25
                 ORDER BY TO_NUMBER(u.ude_value) DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('      '||RPAD(r.account_number,22)||' prod='||RPAD(r.product_code,6)
              ||' rate='||r.rate);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[H.2 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION I : ANOMALIES ET ALERTES TRANSVERSES
    --==========================================================================
    -- Controles de coherence multi-tables qui meritent investigation manuelle.
    --==========================================================================
    section('I','ANOMALIES ET ALERTES');

    sub('I.1  Contrats avec DPD > '||g_dpd_sub||' j MAIS aucun reclassement (NORM/WACH/SACR)');
    -- Crédits qui auraient du etre declasses mais ne l'ont pas ete.
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.product_code, m.amount_disbursed,
                       MAX(g_ref_date - s.schedule_due_date) max_dpd,
                       SUM(NVL(s.amount_due,0)-NVL(s.amount_settled,0)-NVL(s.amount_waived,0)) reste
                  FROM cltb_account_apps_master m
                  JOIN cltb_account_schedules s ON s.account_number = m.account_number
                 WHERE m.account_status='A'
                   AND s.schedule_due_date <= g_ref_date
                   AND NVL(s.amount_due,0)-NVL(s.amount_settled,0)-NVL(s.amount_waived,0) > 0
                   AND NOT EXISTS (
                        SELECT 1 FROM actb_history h
                         WHERE h.related_account = m.account_number
                           AND h.module='CL'
                           AND ( h.amount_tag LIKE '%_NORM_REAL'
                              OR h.amount_tag LIKE '%_WACH_REAL'
                              OR h.amount_tag = 'MAIN_INT_SACR'
                              OR h.amount_tag LIKE '%_SUB_REAL'
                              OR h.amount_tag LIKE '%_DOUB_REAL'
                              OR h.amount_tag LIKE '%_LOSS_REAL' ))
                 GROUP BY m.account_number, m.product_code, m.amount_disbursed
                HAVING MAX(g_ref_date - s.schedule_due_date) >= g_dpd_sub
                 ORDER BY MAX(g_ref_date - s.schedule_due_date) DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.account_number,22)||' prod='||RPAD(r.product_code,6)
              ||' DPD='||LPAD(r.max_dpd,5)
              ||' decaisse='||fmt_n(r.amount_disbursed)
              ||' reste='||fmt_n(r.reste)
              ||' *** AUCUN RECLASSEMENT ***');
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[I.1 err] '||SQLERRM); END;

    sub('I.2  Contrats avec SACR mais sans ecriture cl.9 (985/997) symetrique');
    -- Tout SACR du module CL doit etre adosse a un mouvement 985 (DR) et 997 (CR).
    -- On detecte les ecarts.
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT sacr.related_account,
                       sacr.tot_sacr,
                       NVL(c9.tot_985,0) tot_985,
                       NVL(c9.tot_997,0) tot_997
                  FROM ( SELECT related_account, SUM(lcy_amount) tot_sacr
                           FROM actb_history
                          WHERE module='CL'
                            AND amount_tag='MAIN_INT_SACR'
                            AND drcr_ind='D'
                            AND trn_dt <= g_ref_date
                          GROUP BY related_account ) sacr
                  LEFT JOIN ( SELECT related_account,
                                     SUM(CASE WHEN REGEXP_LIKE(ac_no, g_re_int_reserve_dr)
                                                AND drcr_ind='D' THEN lcy_amount ELSE 0 END) tot_985,
                                     SUM(CASE WHEN REGEXP_LIKE(ac_no, g_re_int_reserve_cr)
                                                AND drcr_ind='C' THEN lcy_amount ELSE 0 END) tot_997
                                FROM actb_history
                               WHERE trn_dt <= g_ref_date
                               GROUP BY related_account ) c9
                    ON c9.related_account = sacr.related_account
                 WHERE ABS(sacr.tot_sacr - NVL(c9.tot_985,0)) > g_tol_recon
                    OR ABS(sacr.tot_sacr - NVL(c9.tot_997,0)) > g_tol_recon
                 ORDER BY sacr.tot_sacr DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.related_account,22)
              ||' SACR='||fmt_n(r.tot_sacr)
              ||' 985='||fmt_n(r.tot_985)
              ||' 997='||fmt_n(r.tot_997)
              ||' ecart_985='||fmt_n(r.tot_sacr - r.tot_985)
              ||' ecart_997='||fmt_n(r.tot_sacr - r.tot_997));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[I.2 err] '||SQLERRM); END;

    sub('I.3  Schedules avec montants negatifs ou sur-paiements');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT account_number, component_name, schedule_due_date,
                       amount_due, amount_settled, amount_waived,
                       amount_settled + NVL(amount_waived,0) - amount_due ecart
                  FROM cltb_account_schedules
                 WHERE amount_settled + NVL(amount_waived,0) > NVL(amount_due,0) + 1
                    OR amount_due < 0 OR amount_settled < 0
                 ORDER BY ABS(amount_settled + NVL(amount_waived,0) - NVL(amount_due,0)) DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.account_number,22)
              ||' '||RPAD(r.component_name,15)
              ||' '||TO_CHAR(r.schedule_due_date,'DD-MON-YY')
              ||' du='||fmt_n(r.amount_due)
              ||' paye='||fmt_n(r.amount_settled)
              ||' remis='||fmt_n(r.amount_waived)
              ||' ecart='||fmt_n(r.ecart));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[I.3 err] '||SQLERRM); END;

    sub('I.4  Contrats actifs sans aucune ecriture CL (anomalie)');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.product_code, m.book_date,
                       m.amount_financed
                  FROM cltb_account_apps_master m
                 WHERE m.account_status='A'
                   AND NOT EXISTS ( SELECT 1 FROM actb_history h
                                     WHERE h.module='CL'
                                       AND h.related_account=m.account_number )
                 ORDER BY m.book_date DESC NULLS LAST
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.account_number,22)||' prod='||RPAD(r.product_code,6)
              ||' book='||TO_CHAR(r.book_date,'DD-MON-YY')
              ||' finance='||fmt_n(r.amount_financed));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[I.4 err] '||SQLERRM); END;

    sub('I.5  Ecart DSBR comptable vs amount_disbursed du contrat');
    BEGIN
        FOR r IN (
            SELECT * FROM (
                SELECT m.account_number, m.amount_disbursed,
                       NVL(a.tot_dsbr,0) tot_dsbr,
                       NVL(a.tot_dsbr,0) - NVL(m.amount_disbursed,0) ecart
                  FROM cltb_account_apps_master m
                  LEFT JOIN ( SELECT related_account,
                                     SUM(CASE WHEN drcr_ind='D' THEN lcy_amount ELSE 0 END) tot_dsbr
                                FROM actb_history
                               WHERE module='CL'
                                 AND amount_tag = 'PRINCIPAL'
                                 AND REGEXP_LIKE(ac_no, g_re_credit_sain)
                                 AND trn_dt <= g_ref_date
                               GROUP BY related_account ) a
                    ON a.related_account = m.account_number
                 WHERE ABS(NVL(a.tot_dsbr,0) - NVL(m.amount_disbursed,0)) > g_tol_recon
                 ORDER BY ABS(NVL(a.tot_dsbr,0) - NVL(m.amount_disbursed,0)) DESC
            ) WHERE ROWNUM <= g_top_n)
        LOOP
            p('   '||RPAD(r.account_number,22)
              ||' contrat='||fmt_n(r.amount_disbursed)
              ||' compta='||fmt_n(r.tot_dsbr)
              ||' ecart='||fmt_n(r.ecart));
        END LOOP;
    EXCEPTION WHEN OTHERS THEN p('[I.5 err] '||SQLERRM); END;

    --==========================================================================
    -- SECTION J : SYNTHESE EXECUTIVE
    --==========================================================================
    -- Resume chiffre destine au rapport d'audit. Donne les ordres de grandeur
    -- pour : encours total, classification, reserves d'interets, dotations
    -- identifiees, anomalies remontees.
    --==========================================================================
    section('J','SYNTHESE EXECUTIVE');

    DECLARE
        v_total_actif       NUMBER := 0;
        v_total_encours     NUMBER := 0;
        v_total_int_imp     NUMBER := 0;
        v_total_sacr        NUMBER := 0;
        v_solde_985         NUMBER := 0;
        v_solde_997         NUMBER := 0;
        v_solde_provisions  NUMBER := 0;
        v_solde_34          NUMBER := 0;
        v_dot_cumul         NUMBER := 0;
        v_rep_cumul         NUMBER := 0;
        v_perte_total       NUMBER := 0;
        v_nb_anom_reclas    NUMBER := 0;
        v_nb_sous_provis    NUMBER := 0;
    BEGIN
        BEGIN
            SELECT COUNT(*), NVL(SUM(amount_disbursed),0)
              INTO v_total_actif, v_total_encours
              FROM cltb_account_apps_master WHERE account_status='A';
        EXCEPTION WHEN OTHERS THEN NULL; END;

        BEGIN
            SELECT NVL(SUM(NVL(amount_due,0)-NVL(amount_settled,0)-NVL(amount_waived,0)),0)
              INTO v_total_int_imp
              FROM cltb_account_schedules
             WHERE component_name='MAIN_INT'
               AND schedule_due_date <= g_ref_date;
        EXCEPTION WHEN OTHERS THEN NULL; END;

        BEGIN
            SELECT NVL(SUM(CASE WHEN drcr_ind='D' THEN lcy_amount ELSE 0 END),0)
              INTO v_total_sacr
              FROM actb_history
             WHERE module='CL' AND amount_tag='MAIN_INT_SACR'
               AND trn_dt <= g_ref_date;
        EXCEPTION WHEN OTHERS THEN NULL; END;

        BEGIN
            SELECT NVL(SUM(CASE WHEN drcr_ind='D' THEN lcy_amount ELSE -lcy_amount END),0)
              INTO v_solde_985
              FROM actb_history
             WHERE REGEXP_LIKE(ac_no, g_re_int_reserve_dr)
               AND trn_dt <= g_ref_date;
        EXCEPTION WHEN OTHERS THEN NULL; END;

        BEGIN
            SELECT NVL(SUM(CASE WHEN drcr_ind='C' THEN lcy_amount ELSE -lcy_amount END),0)
              INTO v_solde_997
              FROM actb_history
             WHERE REGEXP_LIKE(ac_no, g_re_int_reserve_cr)
               AND trn_dt <= g_ref_date;
        EXCEPTION WHEN OTHERS THEN NULL; END;

        BEGIN
            -- solde net du stock de provisions (compte 39x)
            SELECT NVL(SUM(CASE WHEN drcr_ind='C' THEN lcy_amount ELSE -lcy_amount END),0)
              INTO v_solde_provisions
              FROM actb_history
             WHERE REGEXP_LIKE(ac_no, g_re_provisions)
               AND trn_dt <= g_ref_date;
        EXCEPTION WHEN OTHERS THEN NULL; END;

        BEGIN
            SELECT COUNT(*) INTO v_nb_anom_reclas
              FROM cltb_account_apps_master m
             WHERE m.account_status='A'
               AND EXISTS (SELECT 1 FROM cltb_account_schedules s
                            WHERE s.account_number=m.account_number
                              AND s.schedule_due_date <= g_ref_date - g_dpd_sub
                              AND NVL(s.amount_due,0)-NVL(s.amount_settled,0)-NVL(s.amount_waived,0) > 0)
               AND NOT EXISTS (SELECT 1 FROM actb_history h
                                WHERE h.related_account=m.account_number
                                  AND h.module='CL'
                                  AND (h.amount_tag LIKE '%_NORM_REAL'
                                    OR h.amount_tag LIKE '%_WACH_REAL'
                                    OR h.amount_tag='MAIN_INT_SACR'));
        EXCEPTION WHEN OTHERS THEN NULL; END;

        -- cumul des dotations / reprises / pertes sur toute la periode disponible
        BEGIN
            SELECT NVL(SUM(CASE WHEN REGEXP_LIKE(ac_no,g_re_dotations) AND drcr_ind='D' THEN lcy_amount ELSE 0 END),0),
                   NVL(SUM(CASE WHEN REGEXP_LIKE(ac_no,g_re_reprises)  AND drcr_ind='C' THEN lcy_amount ELSE 0 END),0),
                   NVL(SUM(CASE WHEN REGEXP_LIKE(ac_no,g_re_pertes)    AND drcr_ind='D' THEN lcy_amount ELSE 0 END),0),
                   NVL(SUM(CASE WHEN REGEXP_LIKE(ac_no,g_re_creanc_souff)
                                THEN CASE WHEN drcr_ind='D' THEN lcy_amount ELSE -lcy_amount END
                                ELSE 0 END),0)
              INTO v_dot_cumul, v_rep_cumul, v_perte_total, v_solde_34
              FROM actb_history WHERE trn_dt <= g_ref_date;
        EXCEPTION WHEN OTHERS THEN NULL; END;

        -- contrats DOUBT/LOSS sans provision = sous-provisionnement potentiel
        BEGIN
            SELECT COUNT(*) INTO v_nb_sous_provis
              FROM cltb_account_apps_master m
             WHERE m.account_status='A'
               AND EXISTS (SELECT 1 FROM cltb_account_schedules s
                            WHERE s.account_number=m.account_number
                              AND s.schedule_due_date <= g_ref_date - g_dpd_doubt
                              AND NVL(s.amount_due,0)-NVL(s.amount_settled,0)-NVL(s.amount_waived,0) > 0)
               AND NOT EXISTS (SELECT 1 FROM actb_history a
                                WHERE a.related_account=m.account_number
                                  AND a.trn_dt <= g_ref_date
                                  AND ( REGEXP_LIKE(a.ac_no,g_re_provisions)
                                     OR REGEXP_LIKE(a.ac_no,g_re_dotations) ));
        EXCEPTION WHEN OTHERS THEN NULL; END;

        p('  Date evaluation                            : '||TO_CHAR(g_ref_date,'DD-MON-YYYY'));
        p('  Nb contrats actifs (status=A)              : '||LPAD(v_total_actif,15));
        p('  Encours decaisse cumule                    : '||fmt_n(v_total_encours));
        p('  Interets echus impayes                     : '||fmt_n(v_total_int_imp));
        p(' ');
        p('  --- Reserves d''interets (cl.9 hors bilan) ---');
        p('  Cumul MAIN_INT_SACR (tag CL)               : '||fmt_n(v_total_sacr));
        p('  Solde compte 985xxx (DR int. reserves)     : '||fmt_n(v_solde_985));
        p('  Solde compte 997xxx (CR int. reserves)     : '||fmt_n(v_solde_997));
        p(' ');
        p('  --- Cycle de vie PCEC COBAC des provisions (codes confirmes SCB) ---');
        p('  Etape 1 - Dotations cumulees       (DR 691)     : '||fmt_n(v_dot_cumul));
        p('  Etape 2 - Reprises+rentrees cumulees (CR 791+792) : '||fmt_n(v_rep_cumul));
        p('  Etape 3 - Pertes cumulees          (DR 679)     : '||fmt_n(v_perte_total));
        p('  Stock courant provisions           (solde 39)   : '||fmt_n(v_solde_provisions));
        p('  Stock courant creances souffrance  (solde 34)   : '||fmt_n(v_solde_34));
        p(' ');
        p('  --- Anomalies remontees ---');
        p('  Nb contrats DPD>'||g_dpd_sub||'j sans aucun reclassement : '||LPAD(v_nb_anom_reclas,10));
        p('  Nb contrats DPD>'||g_dpd_doubt||'j sans aucune provision : '||LPAD(v_nb_sous_provis,10));
    EXCEPTION WHEN OTHERS THEN p('[J err] '||SQLERRM); END;

    p(' ');
    p(v_sep);
    p('FIN AUDIT PHASE 2');
    p(v_sep);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERREUR GLOBALE : '||SQLERRM);
        DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
END;
/
