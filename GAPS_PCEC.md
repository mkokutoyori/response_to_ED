# Analyse des écarts (gaps) entre `phase2_audit_provisions_cl.sql` et le PCEC COBAC 1998

**Date** : 12-MAY-2026
**Référentiel** : Plan Comptable des Établissements de Crédit (PCEC), COBAC, Règlement R-98/01 du 15 février 1998
**Script évalué** : `phase2_audit_provisions_cl.sql` (commit 1642f69)
**Données de référence** : `exploration_report.txt` (FCUBSLIVE, SCB Cameroun)

---

## Mise à jour du 12-MAY-2026 — Findings de la requête de découverte

La requête `SELECT DISTINCT SUBSTR(ac_no,1,3)...` proposée en §11 a été exécutée sur la base. Résultats sur les classes 6, 7, 9 :

| Code | Libellé SCB | Nb | Statut |
|------|-------------|----|----|
| **691** | DOT PROV DEPREC CLT | **154** | ✅ Dotations confirmées au compte PCEC standard |
| **791** | REP SUR PROV PR DEPREC CPTES CLTELE | **12** | ✅ Reprises confirmées au compte PCEC standard |
| **792** | RENTRÉES SUR CRÉANCES ABANDONNÉES | **2** | ✅ Existe ! À inclure dans le pattern reprises |
| **679** | PERTE SUR OPS CLIENTELE | **31** | ⚠️ **Spécificité SCB** : remplace 6921/6922 |
| 6921 / 6922 | — | **0** | Absents du plan effectif |
| 6913 / 7913 | — | **0** | SCB n'utilise que le niveau 3 chiffres (691, 791) |
| **985** | INTERETS RESERVES SUR CREANCE EN SOUFFRANCE | **870** | ✅ confirmé |
| **997** | INTERETS ET COMMISSION RESERVES | **870** | ✅ confirmé (symétrique 985) |
| 712 | INT. SUR LES CREDITS A MOYEN TERME | 204 615 | ✓ |
| 713 | INT SUR PRET RELATIF AU TRADE | 50 150 | ✓ |
| 714 | INT SUR LES CPTES DEBITEURS DE LA CLIENTELE | 9 913 | ✓ |
| 717 | COMM./CPTES DEBITEURS CLIENTELE | 6 643 | ✓ |
| 719 | PENALITE DE REMBOURSEMENT ANTICIPE | 640 | ✓ |

### Décision actée

Le script `phase2_audit_provisions_cl.sql` a été corrigé en conséquence :

```sql
-- Avant (gap)                        -- Apres (PCEC SCB)
g_re_dotations      := '^693';        g_re_dotations := '^691[0-9]*$';
g_re_reprises       := '^793';        g_re_reprises  := '^79[12][0-9]*$';
g_re_pertes_couv    := '^6921';   →   g_re_pertes    := '^(679|6921|6922)[0-9]*$';
g_re_pertes_noncouv := '^6922';   →   (un seul pattern, SCB n'opere pas la distinction)
```

La section G a été restructurée :
- **G.5** : passage en perte est désormais `DR 679 / CR 34` (sans ventilation couvert/non couvert)
- **G.4** : reprises (791) et rentrées sur créances abandonnées (792) sont distinguées dans l'affichage
- **G.6** : agrégation par contrat ne ventile plus couvert/non couvert (`cum_perte` unique)
- **J Synthèse** : libellés alignés avec les comptes réels SCB

### Implications pour l'analyse

1. Le ratio **dotations (154 écr.) / reprises (12 écr.) = 12,8** indique une période de durcissement net du provisionnement. À investiguer dans G.3 et G.4 par cycle financier (FY2022-FY2026) pour identifier les exercices concernés.

2. Le compte **679 n'a que 31 écritures** au total. Le nombre de **passages en perte effectif** sur la période d'audit est donc très limité. L'audit devra vérifier :
   - si toutes les créances en 345 (autres douteuses) anciennes ont été soit passées en perte (679), soit suffisamment provisionnées (39x)
   - si la pratique SCB de non-distinction `679` vs `6921/6922` est conforme aux exigences COBAC de reporting (CERBER / FINREP)

3. Le compte **792** (rentrées sur créances abandonnées) ne compte que **2 écritures** : taux de recouvrement post-write-off très faible. À examiner les 2 cas.

4. La symétrie parfaite **985 = 870 écr. = 997** confirme que toutes les écritures `MAIN_INT_SACR` du module CL sont correctement adossées en hors-bilan.

---

## Synthèse exécutive

| Gap | Sévérité | Impact sur l'audit |
|----:|---------|--------------------|
| 1 | **CRITIQUE** | Le pattern des comptes de **dotation** vise `693x` qui **n'existe pas en PCEC**. Le bon code est `691` (ou `6913` pour clientèle). Sections G.1, G.2, G.3, G.6, G.7, G.8, J : **aucune dotation ne sera détectée**. |
| 2 | **CRITIQUE** | Le pattern des comptes de **reprise** vise `793x` qui **n'existe pas en PCEC**. Le bon code est `791` (ou `7913`) + `792` pour récupérations. Sections G.1, G.2, G.4, G.6, G.7, J : **aucune reprise ne sera détectée**. |
| 3 | MOYEN | Le pattern `g_re_credit_doubt = '^(328[0-9]{5}8\|345)'` est confus : il mélange créances rattachées et créances en souffrance. À séparer. |
| 4 | MOYEN | Pas de distinction `343 / 344 / 345` (douteuses garanties Etat / garanties sûretés / autres). Taux de provisionnement COBAC différents. |
| 5 | MOYEN | Pas de distinction `341 impayées / 342 immobilisées / 343-345 douteuses` à l'intérieur du compte 34. Granularité COBAC requise. |
| 6 | FAIBLE | Seuils DPD du script (30/90/180/365) issus d'IFRS9, **pas du règlement COBAC** (3 mois immobilisé, 6 mois immobilier, douteux par règlement spécifique). |
| 7 | FAIBLE | Pas de détection des **rentrées sur créances abandonnées** (compte 792), assimilées par PCEC aux reprises de provisions. |
| 8 | INFO | Confirmation : le compte `985` (intérêts à recouvrer) et `997` (intérêts réservés) sont **corrects**. ✓ |
| 9 | INFO | Confirmation : le pattern `39x` pour provisions clientèle est **correct**. ✓ |
| 10 | INFO | Confirmation : `34x` pour créances en souffrance est **correct**. ✓ |

---

## 1. Cadre PCEC vs implémentation SCB Cameroun

### 1.1 Les 9 classes du PCEC COBAC

| Classe | Intitulé PCEC | Usage pour notre audit |
|:------:|---------------|------------------------|
| 1 | Capitaux permanents | non concerné |
| 2 | Valeurs immobilisées | non concerné (provisions 29 hors scope) |
| **3** | **Opérations avec la clientèle** | **cœur de l'audit** — crédits, souffrance, provisions clientèle |
| 4 | Tiers et régularisation | partiellement (484, 487 TVA, comptes d'attente) |
| 5 | Trésorerie et opérations interbancaires | non concerné |
| **6** | **Charges** | dotations 691, pertes 692 |
| **7** | **Produits** | intérêts 711-714, reprises 791, rentrées 792 |
| 8 | Soldes caractéristiques de gestion | non concerné |
| **9** | **Hors bilan** | intérêts réservés 985, 997 |

**À noter** : en PCEC COBAC, **les crédits clientèle sont en classe 3** (≠ SYSCOHADA, qui place les crédits en classe 2). C'est pourquoi les codes `311500100` (SCB) sont bien `31x` = crédits moyen terme.

### 1.2 Codification SCB Cameroun

SCB étend chaque compte PCEC de 3 chiffres avec 6 chiffres internes (total 9 chiffres). Par exemple :

| Code SCB | Décomposition PCEC + ext. interne | Nature |
|----------|------------------------------------|--------|
| `311500100` | `311` (crédits MT) + `500100` (interne) | CREDITS A LA CONSOMMATION MT SAINS |
| `318000100` | `318` (créances rattachées MT) + `000100` | CREANCES RATTACHEES MT SAINS |
| `318000105` | `318` + `000105` | CREANCES RATTACHEES MT (présumé WACH/irrégulier) |
| `328000108` | `328` (créances rattachées CT) + `000108` | CREANCES RATTACHEES CT DOUTE |
| `345100100` | `345` (autres douteuses) + `100100` | AUTRES CREANCES DOUTEUSES… |
| `985100100` | `985` (intérêts à recouvrer souffrance) + `100100` | INTERETS RESERVES SUR CREANCE EN SO |
| `997100100` | `997` (intérêts réservés) + `100100` | INTERETS ET COMMISSION RESERVES |

Les **3 premiers chiffres** suffisent à l'identification PCEC. Les **6 suivants** portent la sous-classification métier interne SCB (et notamment : suffixe `100` = SAINS, `105` = irréguliers/WACH, `108` = doute — à confirmer par la maîtrise d'ouvrage).

---

## 2. Gap 1 — Comptes de **DOTATION** : `693` ≠ `691`

### 2.1 Ce que dit le PCEC (lignes 3717-3746)

> **691 – Dotations aux provisions**
> - 6911 dotations risques et charges
> - 6912 dotations dépréciation valeurs immobilisées (cl. 29)
> - **6913 dotations dépréciation comptes clientèle (cl. 39)** ← celui de notre audit
> - 6914 dotations dépréciation autres comptes tiers (cl. 49)
> - 6915 dotations dépréciation comptes trésorerie (cl. 59)
>
> **692 – Pertes sur créances irrécouvrables**
> - 6921 pertes couvertes par provision
> - 6922 pertes NON couvertes par provision

**Le compte 693 n'existe pas dans le PCEC COBAC.**

### 2.2 Ce qu'écrit mon script

```sql
g_re_dotations  VARCHAR2(40) := '^693[0-9]*$';  -- ÉCHEC : aucun compte 693x dans la base
```

### 2.3 Conséquence

Dans toutes les sections qui s'appuient sur `g_re_dotations` :
- **G.1** Inventaire — colonne « 1-DOTATION 693 » sera vide
- **G.2** Modules créateurs — perdra la classification
- **G.3** Flux annuel des dotations — montrera `0` partout
- **G.6** Cycle par dossier — `cum_dotation = 0`
- **G.7** Cohérence statut/provision — biaisé
- **G.8** Alerte sous-provisionnement — biaisé (le NOT EXISTS sur dotations ne filtre rien)
- **J** Synthèse — « Dotations cumulées » à 0

### 2.4 Correction proposée

```sql
g_re_dotations  VARCHAR2(40) := '^691[0-9]*$';  -- ou plus precis : '^6913[0-9]*$'
```

À valider par requête de découverte : `SELECT DISTINCT ac_no FROM actb_history WHERE REGEXP_LIKE(ac_no,'^69[0-9]+')` avant exécution.

---

## 3. Gap 2 — Comptes de **REPRISE** : `793` ≠ `791`/`792`

### 3.1 Ce que dit le PCEC (lignes 4209-4242)

> **791 – Reprises de provisions**
> - 7911 reprises risques et charges
> - 7912 reprises dépréciation valeurs immobilisées
> - **7913 reprises dépréciation comptes clientèle** ← celui de notre audit
> - 7914 reprises dépréciation autres comptes tiers
> - 7915 reprises dépréciation comptes trésorerie
>
> **792 – Rentrées sur créances abandonnées** (assimilées à reprises de provisions)

**Le compte 793 n'existe pas dans le PCEC COBAC.**

### 3.2 Ce qu'écrit mon script

```sql
g_re_reprises  VARCHAR2(40) := '^793[0-9]*$';  -- ÉCHEC
```

### 3.3 Conséquence

Symétriquement au gap 1 :
- **G.1** Inventaire — colonne « 2-REPRISE 793 » sera vide
- **G.4** Flux annuel des reprises — `0`
- **G.6** `cum_reprise = 0`
- **J** Synthèse — « Reprises cumulées » à 0
- Pertes couvertes (étape 3a) — second leg `DR 394 / CR 7931` non détecté

### 3.4 Correction proposée

```sql
g_re_reprises  VARCHAR2(40) := '^79[12][0-9]*$';  -- 791 reprises + 792 rentrees
-- ou plus precis pour clientele seule :
-- g_re_reprises VARCHAR2(40) := '^7913[0-9]*$';
```

---

## 4. Gap 3 — Pattern `g_re_credit_doubt` confus

### 4.1 Ce qu'écrit mon script

```sql
g_re_credit_doubt VARCHAR2(40) := '^(328[0-9]{5}8|345)';   -- WACH-ish + douteuses melangees
```

### 4.2 Problème

Ce pattern mélange deux logiques :
- `328xxxxx8` = créances **rattachées** court terme douteuses (intérêts courus)
- `345` = créances en **souffrance** elles-mêmes (capital)

Ce sont deux notions distinctes en PCEC (`32` créances saines vs `34` créances en souffrance). Et la chaîne « 345 » n'est pas ancrée à droite, donc elle attrape aussi `3456`, `3457` etc.

### 4.3 Correction proposée

Séparer en patterns distincts par sémantique PCEC :

```sql
-- Capital - creances saines
g_re_capital_sain    VARCHAR2(40) := '^3[012][0-9][0-9]{6}$';  -- 30x, 31x, 32x

-- Capital - creances en souffrance (granularite PCEC)
g_re_souff_impay     VARCHAR2(40) := '^341[0-9]{6}$';  -- impayees
g_re_souff_immob     VARCHAR2(40) := '^342[0-9]{6}$';  -- immobilisees
g_re_souff_dout_etat VARCHAR2(40) := '^343[0-9]{6}$';  -- douteuses garanties Etat
g_re_souff_dout_sur  VARCHAR2(40) := '^344[0-9]{6}$';  -- douteuses garanties sutetes
g_re_souff_dout_aut  VARCHAR2(40) := '^345[0-9]{6}$';  -- autres douteuses
g_re_souff_cb_imp    VARCHAR2(40) := '^346[0-9]{6}$';  -- credit-bail impayees
g_re_souff_cb_dout   VARCHAR2(40) := '^347[0-9]{6}$';  -- credit-bail douteuses

-- Synthese
g_re_creanc_souff    VARCHAR2(40) := '^34[1-7][0-9]{6}$';   -- toutes souffrances

-- Creances rattachees (interets courus)
g_re_ratt_lt         VARCHAR2(40) := '^308[0-9]{6}$';
g_re_ratt_mt         VARCHAR2(40) := '^318[0-9]{6}$';
g_re_ratt_ct         VARCHAR2(40) := '^328[0-9]{6}$';
```

---

## 5. Gap 4 — Pas de distinction 343 / 344 / 345

### 5.1 Pourquoi c'est important

Les **taux de provisionnement COBAC** dépendent de la couverture :

| Classe COBAC | Sous-compte PCEC | Garantie | Taux indicatif |
|---|---|---|---|
| Douteuses couvertes Etat | 343 | Garantie souveraine | très faible / nul |
| Douteuses couvertes sûretés réelles | 344 | Hypothèque, nantissement | partiel |
| Autres douteuses | 345 | Aucune | élevé (>50%) |

Confondre les trois fausse complètement l'évaluation du provisionnement requis.

### 5.2 Correction proposée

Ajouter en section G.6/G.7 une ventilation par sous-compte 34, et un calcul de ratio provision / encours par catégorie.

---

## 6. Gap 5 — Granularité PCEC dans le compte 34

Le PCEC distingue dans le compte 34 :

| Code | Libellé PCEC | Critère |
|---|---|---|
| 341 | Créances impayées | échu non réglé (encours échus) |
| 342 | Créances immobilisées | échu depuis 3+ mois, recouvrement non compromis |
| 343 | Douteuses couvertes Etat | risque probable de non-recouvrement |
| 344 | Douteuses couvertes sûretés réelles | idem, mais avec garantie réelle |
| 345 | Autres douteuses | risque probable, sans couverture particulière |
| 346 | Impayées crédit-bail | idem 341 pour crédit-bail |
| 347 | Douteuses crédit-bail | idem 343-345 pour crédit-bail |

Mon script agrège tout `34x` ensemble. Il faut séparer.

---

## 7. Gap 6 — Seuils DPD : IFRS9 vs COBAC

### 7.1 Ce que dit le PCEC (ligne 1854-1858)

> Créances douteuses = concours présentant impayés **3+ mois** (**6+ pour immobilier**), risque probable de non-recouvrement, ou caractère contentieux.

### 7.2 Ce qu'utilise mon script

```sql
g_dpd_wach   NUMBER := 30;   -- 30 j
g_dpd_sub    NUMBER := 90;   -- 90 j (3 mois) ✓ aligne PCEC
g_dpd_doubt  NUMBER := 180;  -- 180 j (6 mois) ≈ aligne PCEC immobilier
g_dpd_loss   NUMBER := 365;  -- 365 j (1 an)
```

### 7.3 Constat

- `g_dpd_sub = 90j` correspond bien au seuil COBAC « 3 mois » pour le déclassement en immobilisé/douteux.
- `g_dpd_doubt = 180j` correspond au seuil « 6 mois pour immobilier ».
- `g_dpd_wach = 30j` est une convention IFRS9 (Stage 2), pas un seuil PCEC. À conserver comme alerte précoce, mais ne crée **pas** d'obligation comptable PCEC.
- `g_dpd_loss = 365j` n'est pas dans le PCEC ; la mise en perte (passage en 692) est décidée au cas par cas par la banque, validée COBAC.

### 7.4 Correction proposée

Documenter dans les commentaires que :
- les seuils **PCEC/COBAC** sont `0/90/180` (impayé/immobilisé ou douteux/douteux immobilier)
- la classe `WACH = DPD ∈ [1, 89]` est une **convention de gestion interne**, pas une catégorie comptable PCEC
- la classe `LOSS = DPD > 365` est une **convention de seuil de mise en perte**, à ajuster selon politique SCB.

---

## 8. Gap 7 — Rentrées sur créances abandonnées (compte 792)

Le PCEC (ligne 4239-4242) assimile les **rentrées sur créances abandonnées** (compte 792) aux reprises de provisions. Mon script ne les capture pas (pattern `^793` qui n'existe pas).

Si une créance a été passée en perte (6922) puis le client paie finalement, on enregistre :
```
DR 5xx (caisse / compte client)  CR 792 Rentrées sur créances abandonnées
```

C'est un **gain pour la banque** qui doit être suivi à l'audit.

Correction : inclure `792` dans le pattern reprises (cf. gap 2).

---

## 9. Confirmations (pas de gap)

### 9.1 Provisions dépréciation clientèle — compte 39

Mon script :
```sql
g_re_provisions VARCHAR2(40) := '^39[0-9]+$';
```

PCEC :
- 391 Provisions créances impayées
- 392 Provisions créances immobilisées
- 393 Provisions créances douteuses garanties Etat
- 394 Provisions créances douteuses sûretés réelles
- 395 Provisions impayées crédit-bail
- 396 Provisions douteuses crédit-bail

✅ Le pattern est correct. À envisager : granularité par sous-compte.

### 9.2 Pertes couvertes / non couvertes — comptes 6921 / 6922

Mon script :
```sql
g_re_pertes_couv    VARCHAR2(40) := '^6921[0-9]*$';
g_re_pertes_noncouv VARCHAR2(40) := '^6922[0-9]*$';
```

✅ Conforme PCEC.

### 9.3 Intérêts réservés hors bilan — comptes 985 / 997

Mon script :
```sql
g_re_int_reserve_dr VARCHAR2(40) := '^985[0-9]{6}$';
g_re_int_reserve_cr VARCHAR2(40) := '^997[0-9]{6}$';
```

PCEC :
- 9851 Intérêts sur créances en souffrance (« Produits et taxes à recouvrer »)
- 9971 Intérêts réservés (compte de contrepartie)

✅ Conforme. Le schéma `DR 985 / CR 997` du tag `MAIN_INT_SACR` est bien le mécanisme PCEC de mise en réserve des intérêts sur créances en souffrance.

### 9.4 Créances en souffrance — compte 34

Mon script :
```sql
g_re_creanc_souff VARCHAR2(40) := '^34[0-9]+$';
```

✅ Couvre 341 à 347 (souffrance + crédit-bail). À enrichir avec la granularité fine (gap 5).

### 9.5 Produits d'intérêts — comptes 71

Mon script :
```sql
g_re_revenue_int VARCHAR2(40) := '^71[0-9]{6}$';
```

PCEC :
- 711 Intérêts crédits long terme
- 712 Intérêts crédits moyen terme
- 713 Intérêts crédits court terme
- 714 Intérêts comptes débiteurs
- 715 Crédit-bail
- 717 Commissions
- 719 Autres

✅ Conforme.

---

## 10. Tableau récapitulatif des corrections à appliquer

| Variable script | Valeur actuelle | Valeur PCEC-conforme | Sévérité |
|-----------------|-----------------|----------------------|----------|
| `g_re_dotations` | `^693[0-9]*$` | `^691[0-9]*$` (ou `^6913[0-9]*$`) | **CRITIQUE** |
| `g_re_reprises` | `^793[0-9]*$` | `^79[12][0-9]*$` (ou `^7913[0-9]*$`) | **CRITIQUE** |
| `g_re_credit_doubt` | `^(328[0-9]{5}8\|345)` | À découper (cf. gap 3) | MOYEN |
| `g_re_pertes_couv` | `^6921[0-9]*$` | inchangé ✓ | — |
| `g_re_pertes_noncouv` | `^6922[0-9]*$` | inchangé ✓ | — |
| `g_re_creanc_souff` | `^34[0-9]+$` | inchangé ✓ (mais ajouter granularité 341/342/343/344/345) | MOYEN |
| `g_re_provisions` | `^39[0-9]+$` | inchangé ✓ | — |
| `g_re_int_reserve_dr` | `^985[0-9]{6}$` | inchangé ✓ | — |
| `g_re_int_reserve_cr` | `^997[0-9]{6}$` | inchangé ✓ | — |
| `g_re_revenue_int` | `^71[0-9]{6}$` | inchangé ✓ | — |

---

## 11. Étapes recommandées avant correction du script

1. **Lancer une requête de découverte** pour confirmer les codes effectivement utilisés par SCB :
   ```sql
   SELECT DISTINCT SUBSTR(a.ac_no,1,3) prefix_pcec,
          MIN(s.ac_gl_desc) libelle_exemple,
          COUNT(*) nb
     FROM actb_history a
     LEFT JOIN sttb_account s ON s.ac_gl_no = a.ac_no
    WHERE SUBSTR(a.ac_no,1,1) IN ('6','7','9')
    GROUP BY SUBSTR(a.ac_no,1,3)
    ORDER BY 1;
   ```
   Cela permettra de **vérifier que `691`, `792`, `7913` sont bien utilisés**, et qu'il n'existe pas de codification SCB déviante.

2. **Vérifier l'usage de 6912 vs 6913 vs 691** : si la banque ne ventile pas la dotation par classe (cas fréquent), elle peut écrire directement sur `691` sans suffixe. Si elle ventile, viser `6913` pour la dépréciation clientèle.

3. **Demander à la MOA SCB** :
   - la signification des suffixes internes `100/105/108` (présumés SAIN/WACH/DOUTE)
   - le règlement COBAC applicable pour les seuils de déclassement (R-2003/04 ou évolution)
   - la politique interne pour la mise en perte définitive (seuil temporel et procédure)

4. **Corriger le script en deux passes** :
   - Passe 1 : remplacer `693` → `691` et `793` → `79[12]`
   - Passe 2 : ajouter la granularité 341/342/343/344/345/346/347 et le ratio provision/encours par sous-classe

---

## 12. Impact estimé sur les résultats si on relance le script en l'état

| Section | Avant correction (état actuel) | Après corrections gap 1 + gap 2 |
|---------|-------------------------------|----------------------------------|
| G.1 Inventaire | seules les colonnes 39/34/6921/6922 sont peuplées | toutes peuplées |
| G.3 Dotations annuelles | toutes à zéro | montants réels |
| G.4 Reprises annuelles | toutes à zéro | montants réels |
| G.5 Pertes 6921/6922 | partiellement correct (les pertes oui, mais le second leg « DR 39/CR 791 » manque) | complet |
| G.6 Cycle par dossier | `cum_dotation = 0`, `cum_reprise = 0` | valeurs réelles |
| G.8 Alerte sous-provisionnement | trop permissive : tous les contrats sans 693x seront flaggés (= tous) | filtrage pertinent |
| J Synthèse | dotations et reprises = 0 | chiffres réalistes |

**Conclusion** : en l'état, **les sections G.3, G.4, G.6 (parties dot/rep), G.8, et la synthèse J donnent des résultats faussement nuls**. Les autres sections (D, E, F, H, I, et G.1/G.2 partiellement) restent fiables.
