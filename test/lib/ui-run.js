/* Exécute le JavaScript du panneau sous node, avec un DOM simulé, et vérifie le rendu de
   la vue d'accès. C'est l'étape que « node --check » ne remplace pas : ici le code TOURNE,
   donc une variable non déclarée ou un appel sur undefined lèvent. */
"use strict";
const path = require("path");
const stub = require(path.join(__dirname, "dom-stub.js"));

const APP = process.argv[2];
if (!APP) { console.error("usage : ui-run.js <chemin/vers/app.js>"); process.exit(2); }

const env = stub.install([]);
let app;
try {
  app = require(path.resolve(APP));
} catch (e) {
  console.log("  KO   le chargement du panneau lève : " + e.message);
  process.exit(1);
}

let pass = 0, fail = 0;
function ok(m) { console.log("  OK   " + m); pass++; }
function ko(m, got, want) {
  console.log("  KO   " + m);
  if (arguments.length > 1) {
    console.log("       obtenu  : [" + got + "]");
    console.log("       attendu : [" + want + "]");
  }
  fail++;
}
function eq(m, got, want) { if (got === want) { ok(m); } else { ko(m, got, want); } }
function contient(m, texte, motif) {
  if (String(texte).indexOf(motif) >= 0) { ok(m); } else { ko(m, texte, "contient " + motif); }
}

if (typeof app.renderAcces !== "function") {
  ko("la couture de test n'expose pas renderAcces");
  process.exit(1);
}
ok("le panneau se charge et s'exécute sans lever");

function G(id, libelle, appareils, flux, auto) {
  return {id: id, libelle: libelle, appareils: appareils, flux: flux || [], auto: !!auto};
}
function F(id, dest, label, proto, ports, sens) {
  return {id: id, dest: dest, label: label, proto: proto || "any",
          ports: ports || "", sens: sens || "aller", titre: ""};
}
function render(acces) {
  app.setState({acces: acces, peers: [], server: {}, time: 1});
  app.renderAcces();
  return {
    etat: env.doc.getElementById("acc-state"),
    warn: env.doc.getElementById("acc-warn"),
    matrix: env.doc.getElementById("acc-matrix"),
    listen: env.doc.getElementById("acc-listen")
  };
}
function vide() {
  return {mode: "ouvert", noyau: "inactif", groupes: [], ressources: [], ecoute: []};
}

/* --- bandeau d'état : il doit refléter le NOYAU, pas le fichier ------------- */
let r = render(vide());
eq("mode ouvert : aucun cloisonnement", r.etat.textContent, "Aucun cloisonnement");
eq("mode ouvert : pas d'avertissement", r.warn.hidden, true);

r = render({mode: "filtre", noyau: "actif", groupes: [], ressources: [], ecoute: []});
eq("filtrage actif", r.etat.textContent, "Filtrage actif");
eq("classe de la pastille", r.etat.className, "pill ok");
eq("filtrage actif : pas d'avertissement", r.warn.hidden, true);

/* Le cas qui compte : le fichier demande le filtrage, mais le noyau ne l'applique pas —
   après un « ufw reload » ou un redémarrage de Docker. Le panneau doit le dire, et
   surtout ne jamais annoncer un cloisonnement inexistant. */
r = render({mode: "filtre", noyau: "incoherent", groupes: [], ressources: [], ecoute: []});
eq("règles non appliquées", r.etat.textContent, "Règles non appliquées");
eq("pastille en rouge", r.etat.className, "pill bad");
eq("avertissement visible", r.warn.hidden, false);
contient("l'avertissement est explicite", r.warn.textContent, "PAS appliquées");

r = render({mode: "filtre", noyau: "inconnu", groupes: [], ressources: [], ecoute: []});
eq("état non vérifiable : pastille neutre", r.etat.textContent, "Filtrage demandé");
eq("état non vérifiable : averti quand même", r.warn.hidden, false);

/* --- matrice --------------------------------------------------------------- */
r = render(vide());
contient("aucune règle : message au lieu d'un tableau vide", stub.textOf(r.matrix), "Aucune règle");

const acces = {
  mode: "filtre", noyau: "actif", ecoute: [22, 443],
  ressources: [{id: "nas", libelle: "NAS", cible: "192.168.1.20"}],
  groupes: [
    G("confiance", "Appareils de confiance", ["telephone", "pc"], [
      F("p1", "res:nas", "NAS (192.168.1.20)", "tcp", "445,5000-5001"),
      F("p2", "internet", "Internet")
    ]),
    G("invites", "Invités", ["tablette"], [F("p3", "internet", "Internet")]),
    G("tous", "Tous les appareils", ["telephone", "pc", "tablette"], [], true)
  ]
};
r = render(acces);
const tables = stub.findAll(r.matrix, "TABLE");
eq("un seul tableau", tables.length, 1);
const entetes = stub.findAll(stub.findAll(tables[0], "THEAD")[0], "TH");
eq("coin + deux destinations", entetes.length, 3);
eq("première colonne : le coin", entetes[0].className, "corner");
/* Internet avant la ressource : le trafic de masse en premier, comme dans les règles. */
eq("Internet avant la ressource", entetes[1].textContent, "Internet");
eq("la ressource ensuite", entetes[2].textContent, "NAS (192.168.1.20)");

const lignes = stub.findAll(stub.findAll(tables[0], "TBODY")[0], "TR");
eq("une ligne par groupe", lignes.length, 3);
const cellules = stub.findAll(lignes[0], "TD");
eq("deux cellules sur la première ligne", cellules.length, 2);
eq("accès accordé vers Internet", cellules[0].className, "yes");
eq("accès accordé vers la ressource", cellules[1].className, "yes");
contient("les ports sont affichés tels que saisis", stub.textOf(cellules[1]), "445,5000-5001");

/* Une cellule sans règle doit être HACHURÉE et non vide : « aucune règle » ne doit pas se
   confondre avec « pas encore chargé ». */
const sansRegle = stub.findAll(lignes[1], "TD")[1];
eq("absence de règle marquée", sansRegle.className, "no");
eq("absence de règle annoncée aux lecteurs d'écran", sansRegle.getAttribute("aria-label"), "aucune règle");

contient("le groupe automatique est signalé", stub.textOf(stub.findAll(lignes[2], "TH")[0]), "automatique");
contient("le nombre d'appareils est affiché", stub.textOf(lignes[0]), "2 appareils");

/* --- ports en écoute ------------------------------------------------------- */
eq("note des ports visible", r.listen.hidden, false);
contient("les ports en écoute sont listés", r.listen.textContent, "22, 443");
r = render(vide());
eq("note masquée sans port", r.listen.hidden, true);

/* --- formatage ------------------------------------------------------------- */
eq("protocole any", app.fluxTexte(F("x", "internet", "Internet")), "tout");
eq("protocole et ports", app.fluxTexte(F("x", "internet", "I", "tcp", "443")), "tcp 443");
eq("sens deux signalé", app.fluxTexte(F("x", "grp:a", "A", "any", "", "deux")), "tout ⇄");
/* Ce qui compte est l ORDRE des colonnes, pas la valeur des rangs : fixer les nombres
   faisait echouer trois tests au seul ajout d une destination, sans qu aucun
   comportement visible ait change. */
eq("les colonnes vont du plus large au plus precis",
   ["grp:a", "res:nas", "pi", "maison", "internet", "tout"]
     .sort(function (x, y) { return app.destRang(x) - app.destRang(y); }).join(" "),
   "tout internet maison pi res:nas grp:a");
eq("une destination inconnue ne casse pas le tri",
   typeof app.destRang("quelque-chose"), "number");

/* --- robustesse : un état incomplet ne doit pas faire planter le panneau ---- */
try {
  app.setState({acces: {}, peers: [], server: {}, time: 1});
  app.renderAcces();
  ok("une vue d'accès vide ne lève pas");
} catch (e) {
  ko("une vue d'accès vide lève : " + e.message);
}
try {
  app.setState({peers: [], server: {}, time: 1});
  app.renderAcces();
  ok("une réponse sans vue d'accès ne lève pas");
} catch (e) {
  ko("une réponse sans vue d'accès lève : " + e.message);
}


/* --- carte ----------------------------------------------------------------- */
function P(name, groupes, down, up, enabled, connected) {
  return {name: name, ip: "10.8.0.2", groupes: groupes, down: down || 0, up: up || 0,
          enabled: enabled !== false, connected: !!connected, rx: 0, tx: 0, mode: "split"};
}
function renderCarte(acces, peers) {
  app.mapReset();
  app.setState({acces: acces, peers: peers, server: {}, time: 1});
  app.renderMap();
  return env.doc.getElementById("map-box");
}

const accesCarte = {
  mode: "filtre", noyau: "actif", ecoute: [],
  ressources: [{id: "nas", libelle: "NAS", cible: "192.168.1.20"}],
  groupes: [
    G("confiance", "Confiance", ["telephone"], [
      F("p1", "internet", "Internet"),
      F("p2", "res:nas", "NAS (192.168.1.20)", "tcp", "445")
    ]),
    G("invites", "Invités", ["tablette"], [F("p3", "internet", "Internet", "any", "", "deux")])
  ]
};
const pairs = [
  P("telephone", ["confiance", "tous"], 500000, 100000, true, true),
  P("tablette", ["invites", "tous"], 0, 0, true, false),
  P("vieux-pc", ["tous"], 0, 0, false, false)
];

let box = renderCarte(accesCarte, pairs);
let svgs = stub.findAll(box, "SVG");
eq("un SVG est produit", svgs.length, 1);
const liens = stub.findAll(svgs[0], "PATH");

function parClasse(motif) {
  return liens.filter(function (l) { return (l.getAttribute("class") || "").indexOf(motif) >= 0; });
}
eq("un lien par appareil vers le Pi", parClasse("axis").length, 3);

/* Un appareil qui ne transmet rien ne doit PAS etre anime : un point qui circule sur une
   liaison inactive serait un mensonge visuel. */
const animes = parClasse("live");
eq("seul l appareil qui transmet est animé", animes.length, 1);
eq("l appareil animé est le bon", animes[0].getAttribute("data-dev"), "telephone");
eq("palier de vitesse intermédiaire", animes[0].getAttribute("class").indexOf("s2") >= 0, true);

const coupe = liens.filter(function (l) { return l.getAttribute("data-dev") === "vieux-pc"; })[0];
contient("un appareil désactivé est marqué", coupe.getAttribute("class"), "off");
eq("un appareil désactivé n est jamais animé", coupe.getAttribute("class").indexOf("live"), -1);

/* L intensite doit passer par stroke-opacity : un « opacity » en style inline
   l emporterait sur la feuille de style et bloquerait l estompage du mode focus. */
eq("intensité portée par stroke-opacity", typeof animes[0].style.strokeOpacity, "string");
eq("aucune opacity inline", animes[0].style.opacity === undefined || animes[0].style.opacity === "", true);

const pol = parClasse("pol");
eq("trois arêtes de politique", pol.length, 3);
contient("couleur de groupe sur l arête", pol[0].getAttribute("class"), "g1");
eq("tous les ports : trait épais", parClasse("wide").length, 2);
eq("sens unique : trait pointillé", parClasse("oneway").length, 2);
/* Le trafic ne doit JAMAIS animer une arete de politique : rien ne permet d attribuer
   un debit a une regle precise. */
eq("aucune arête de politique animée", pol.filter(function (l) {
  return (l.getAttribute("class") || "").indexOf("live") >= 0;
}).length, 0);

eq("paliers de débit", [app.mapTier(1000), app.mapTier(500000), app.mapTier(5000000)].join(","), "1,2,3");
eq("débit en Mo/s", app.humanRate(2500000), "2.5 Mo/s");
eq("débit en ko/s", app.humanRate(45000), "45 ko/s");
eq("débit en o/s", app.humanRate(300), "300 o/s");

/* --- mode focus ------------------------------------------------------------ */
/* Le focus doit suivre le CHEMIN COMPLET. Les liens de gauche portent « data-dev »,
   ceux de droite « data-grp » et « data-dest » : une mise en evidence qui ne filtre que
   sur l attribut du type clique s arrete au Pi, et laisse croire que la question
   « et ensuite, qu est-ce qu il atteint ? » n a pas de reponse. */
function noeudCarte(svg, attr, val) {
  return stub.findAll(svg, "G").filter(function (g) { return g.getAttribute(attr) === val; })[0];
}
function vueFocus() {
  const s = stub.findAll(env.doc.getElementById("map-box"), "SVG")[0];
  function marques(liste) {
    return liste.filter(function (e) { return (e.getAttribute("class") || "").indexOf("sel") >= 0; });
  }
  return {svg: s, liens: marques(stub.findAll(s, "PATH")), noeuds: marques(stub.findAll(s, "G"))};
}

app.mapClick(noeudCarte(svgs[0], "data-dev", "telephone"));
eq("le focus est mémorisé", app.mapFocusKey(), "dev:telephone");
let vf = vueFocus();
contient("le SVG passe en mode focus", vf.svg.getAttribute("class"), "focus");
/* « telephone » est dans « confiance », qui mene a Internet et au NAS : son lien vers le
   Pi, plus ces deux regles. */
eq("le chemin ne s arrête pas au Pi", vf.liens.length, 3);
eq("les destinations joignables sont allumées",
   vf.noeuds.filter(function (g) { return g.getAttribute("data-dest"); })
     .map(function (g) { return g.getAttribute("data-dest"); }).sort().join(","),
   "internet,res:nas");
/* Un lien de politique n est retenu que si SES DEUX bouts le sont : sinon, selectionner
   un appareil allumerait la regle d un AUTRE groupe vers la meme destination, et
   donnerait a lire un droit qu il n a pas. */
eq("la règle de l autre groupe reste éteinte",
   vf.liens.filter(function (l) { return l.getAttribute("data-grp") === "invites"; }).length, 0);
eq("l appareil d un autre groupe reste éteint",
   vf.liens.filter(function (l) { return l.getAttribute("data-dev") === "tablette"; }).length, 0);
/* « sel » et non « on » : « on » marque deja les appareils connectes. */
eq("le marqueur de focus n est pas « on »", vf.liens[0].getAttribute("class").indexOf(" on"), -1);
app.mapClick(noeudCarte(vf.svg, "data-dev", "telephone"));
eq("un second clic rétablit tout", app.mapFocusKey(), null);

/* Symétrie : une destination montre QUI peut l atteindre. */
svgs = stub.findAll(env.doc.getElementById("map-box"), "SVG");
app.mapClick(noeudCarte(svgs[0], "data-dest", "internet"));
eq("le focus retient la destination", app.mapFocusKey(), "dest:internet");
vf = vueFocus();
/* Deux groupes menent a Internet : les deux appareils, leurs liens vers le Pi, et les
   deux regles. */
eq("les deux appareils et leurs règles", vf.liens.length, 4);
eq("la règle vers le NAS reste éteinte",
   vf.liens.filter(function (l) { return l.getAttribute("data-dest") === "res:nas"; }).length, 0);
app.mapClick(noeudCarte(vf.svg, "data-dest", "internet"));
eq("un second clic rétablit tout (destination)", app.mapFocusKey(), null);

/* --- cas limites ----------------------------------------------------------- */
box = renderCarte(accesCarte, []);
eq("aucun appareil : aucune carte", stub.findAll(box, "SVG").length, 0);
/* Et pas un volet BLANC pour autant : les quatre autres vues ont toutes leur texte de
   vide, celle-ci sortait avant d en poser un. */
contient("aucun appareil : un texte de vide", stub.textOf(box), "Aucun appareil");
/* La legende decrivait alors des traits et des pointilles absents du volet. */
eq("aucun appareil : la legende se tait", env.doc.getElementById("map-legend").hidden, true);
eq("et elle est videe", env.doc.getElementById("map-legend").textContent, "");
try {
  renderCarte({}, pairs);
  ok("une carte sans règles ne lève pas");
} catch (e) {
  ko("une carte sans règles lève : " + e.message);
}
eq("la légende est posée", env.doc.getElementById("map-legend").hidden, false);

/* La légende ne doit décrire que ce qui est à l'écran : sans règle, pas d'arête de
   politique, donc pas un mot sur leur épaisseur ni leurs pointillés. */
renderCarte({mode: "ouvert", noyau: "inactif", groupes: [], ressources: [], ecoute: []}, pairs);
const legSansRegle = env.doc.getElementById("map-legend").textContent;
contient("sans règle, la légende annonce la colonne vide", legSansRegle, "se remplira");
eq("sans règle, elle ne parle pas de trait épais", legSansRegle.indexOf("trait épais"), -1);
eq("sans règle, elle ne parle pas de pointillé", legSansRegle.indexOf("pointillé"), -1);
contient("elle parle quand même du débit", legSansRegle, "débit réel");

renderCarte(accesCarte, pairs);
const legAvecRegle = env.doc.getElementById("map-legend").textContent;
contient("avec des règles, elle décrit le trait épais", legAvecRegle, "trait épais");
contient("et le mode focus", legAvecRegle, "Cliquez");


/* --- fiche d'accès d'un appareil ------------------------------------------- */
const accesFiche = {
  mode: "filtre", noyau: "actif", ecoute: [],
  ressources: [{id: "nas", libelle: "NAS", cible: "192.168.1.20"}],
  groupes: [
    G("famille", "Ma famille", ["telephone", "pc"], [
      F("p1", "internet", "Internet"),
      F("p2", "res:nas", "NAS (192.168.1.20)", "tcp", "445")
    ]),
    G("invites", "Invités", ["tablette"], [
      F("p3", "internet", "Internet"),
      F("p4", "grp:famille", "Le groupe « Ma famille »", "any", "", "deux")
    ]),
    G("tous", "Tous les appareils", ["telephone", "pc", "tablette"], [F("p5", "pi", "Le Raspberry Pi lui-même")], true)
  ]
};
const pairsFiche = [
  P("telephone", ["famille", "tous"], 0, 0, true, true),
  P("solitaire", ["tous"], 0, 0, true, false)
];
app.setState({acces: accesFiche, peers: pairsFiche, server: {}, time: 1});

eq("groupes nommés, « tous » exclu", app.groupesNommes(pairsFiche[0]).join(","), "famille");
eq("un appareil sans groupe nommé", app.groupesNommes(pairsFiche[1]).length, 0);

/* Les flux sortants cumulent les groupes de l'appareil, « tous » compris. */
const sortants = app.fluxSortants("telephone");
eq("trois flux sortants pour telephone", sortants.length, 3);
eq("dont la règle du groupe automatique", sortants.filter(function (x) {
  return x.flux.id === "p5";
}).length, 1);
eq("un appareil sans groupe nommé hérite de « tous »", app.fluxSortants("solitaire").length, 1);
eq("un appareil inconnu n'a aucun flux", app.fluxSortants("fantome").length, 0);

/* Les flux entrants : les règles dont la destination est un groupe dont il fait partie. */
const entrants = app.fluxEntrants("telephone");
eq("un flux entrant vers telephone", entrants.length, 1);
eq("il vient du bon groupe", entrants[0].groupe.id, "invites");
eq("et il est bidirectionnel", entrants[0].flux.sens, "deux");
eq("personne ne peut joindre solitaire", app.fluxEntrants("solitaire").length, 0);

/* La fiche s'ouvre et se remplit sans lever. */
try {
  app.openAcces("telephone");
  const corps = env.doc.getElementById("dlg-body");
  const txt = stub.textOf(corps);
  ok("la fiche s'ouvre sans lever");
  contient("le titre nomme l'appareil", txt, "telephone");
  contient("les groupes sont listés", txt, "Ma famille");
  contient("ce qu'il peut joindre", txt, "Peut joindre");
  contient("ce qui peut le joindre", txt, "Peut être joint par");
  contient("les ports sont affichés", txt, "tcp 445");
  /* La limite doit être dite dans la fiche, pas découverte à ses frais. */
  contient("la limite des services du Pi est rappelée", txt, "services qui tournent sur le Pi");
} catch (e) {
  ko("la fiche lève : " + e.message);
}

/* Hors filtrage, la fiche doit dire que rien ne s'applique : sans cela, la liste se
   lirait comme une restriction effective. */
try {
  app.setState({acces: Object.assign({}, accesFiche, {mode: "ouvert"}), peers: pairsFiche, server: {}, time: 1});
  app.openAcces("telephone");
  contient("hors filtrage, la fiche le dit", stub.textOf(env.doc.getElementById("dlg-body")),
           "Aucun cloisonnement");
} catch (e) {
  ko("la fiche lève hors filtrage : " + e.message);
}
try {
  app.setState({acces: Object.assign({}, accesFiche, {noyau: "incoherent"}), peers: pairsFiche, server: {}, time: 1});
  app.openAcces("telephone");
  contient("règles non appliquées : la fiche le dit", stub.textOf(env.doc.getElementById("dlg-body")),
           "ne sont PAS appliquées");
} catch (e) {
  ko("la fiche lève sur un état incohérent : " + e.message);
}
try {
  app.setState({acces: {}, peers: pairsFiche, server: {}, time: 1});
  app.openAcces("telephone");
  ok("une fiche sans vue d'accès ne lève pas");
} catch (e) {
  ko("une fiche sans vue d'accès lève : " + e.message);
}

/* ---- Groupes, ressources, règles et bascule ---- */
const accesGestion = {
  mode: "filtre", noyau: "actif", confirme: false,
  groupes: [
    G("famille", "Ma famille", ["telephone", "tablette"],
      [F("r1", "internet", "Internet"), F("r2", "res:nas", "Le NAS", "tcp", "445,5000-5001")]),
    G("vide", "Groupe sans personne", []),
    G("tous", "Tous les appareils", ["telephone"], [], true)
  ],
  ressources: [{id: "nas", libelle: "Le NAS", cible: "192.168.1.20"}],
  ecoute: [22, 443]
};
const pairsGestion = [{name: "telephone"}, {name: "tablette"}, {name: "pc-bureau"}];

function rendreGestion(acces, pairs) {
  app.setState({acces: acces, peers: pairs || pairsGestion, server: {}, time: 1});
  app.renderGroupes();
  app.renderRegles();
  app.renderConfirmation();
  app.majBascule();
  return {
    groupes: env.doc.getElementById("grp-list"),
    ressources: env.doc.getElementById("res-list"),
    regles: env.doc.getElementById("acc-rules"),
    bandeau: env.doc.getElementById("acc-confirm"),
    bascule: env.doc.getElementById("acc-switch"),
    cGrp: env.doc.getElementById("c-grp"),
    cAcc: env.doc.getElementById("c-acc")
  };
}

let v = rendreGestion(accesGestion);
contient("le groupe est affiché avec son libellé", stub.textOf(v.groupes), "Ma famille");
contient("ses appareils apparaissent", stub.textOf(v.groupes), "telephone");
contient("un groupe vide le dit", stub.textOf(v.groupes), "aucun appareil");
/* « tous » est automatique : on ne le propose ni à la suppression ni à l'ajout de membres. */
eq("le groupe automatique n est pas listé", stub.textOf(v.groupes).indexOf("Tous les appareils"), -1);
eq("compteur des groupes nommés", v.cGrp.textContent, "2");
eq("compteur des règles", v.cAcc.textContent, "2");
contient("la ressource montre son adresse", stub.textOf(v.ressources), "192.168.1.20");

contient("la règle nomme sa destination", stub.textOf(v.regles), "Le NAS");
contient("les ports sont lisibles", stub.textOf(v.regles), "TCP 445,5000-5001");
contient("une règle sans port dit tous les ports", stub.textOf(v.regles), "tous les ports");
eq("une ligne par règle", stub.findAll(v.regles, "DIV").filter(function (d) {
  return d.className === "regle";
}).length, 2);

/* Le bandeau de confirmation se déduit de l'état du serveur, jamais d'une variable
   locale : sinon il disparaîtrait au premier rechargement de page, alors que le
   retour arrière automatique, lui, serait toujours armé. */
eq("filtrage non confirmé : le bandeau s affiche", v.bandeau.hidden, false);
contient("et il explique ce qui va se passer", stub.textOf(v.bandeau), "rétablira");
eq("filtrage actif : la bascule propose de couper", v.bascule.textContent, "Couper le filtrage");

v = rendreGestion(Object.assign({}, accesGestion, {confirme: true}));
eq("filtrage confirmé : pas de bandeau", v.bandeau.hidden, true);

v = rendreGestion(Object.assign({}, accesGestion, {mode: "ouvert"}));
eq("sans filtrage : pas de bandeau", v.bandeau.hidden, true);
eq("sans filtrage : la bascule propose d activer", v.bascule.textContent, "Activer le filtrage");

v = rendreGestion({});
contient("aucun groupe : le panneau le dit", stub.textOf(v.groupes), "Aucun groupe");
contient("aucune ressource : le panneau le dit", stub.textOf(v.ressources), "Aucune ressource");
contient("aucune règle : le panneau le dit", stub.textOf(v.regles), "Aucune règle");
eq("compteurs vides plutôt que zéro", v.cGrp.textContent + "/" + v.cAcc.textContent, "/");

/* --- ce que la relecture a corrigé ----------------------------------------- */
const source = require("fs").readFileSync(APP, "utf8");

/* /api/filtrage EXIGE une action : un corps vide lui fait répondre 400 « Action
   inconnue. ». C'est ainsi que « Couper le filtrage » est resté mort — le seul moyen,
   depuis le navigateur, de défaire un cloisonnement qui vous enferme. */
let sansAction = 0, pos = -1;
while ((pos = source.indexOf("/api/filtrage", pos + 1)) >= 0) {
  if (source.slice(pos, pos + 180).indexOf("action") < 0) { sansAction += 1; }
}
eq("chaque appel à /api/filtrage porte une action", sansAction, 0);

v = rendreGestion(accesGestion);
const pastilles = stub.findAll(v.groupes, "SPAN").filter(function (s) {
  return (s.className || "").indexOf("chip") >= 0;
});
/* « data-admin » masque l élément pour un compte de consultation. Posé sur la pastille
   entière, il masquait le NOM de l appareil : les groupes apparaissaient vides, ce qui
   est un mensonge et non une restriction. Il va sur le bouton de retrait. */
eq("la pastille d appartenance reste visible en lecture seule",
   pastilles.filter(function (s) { return s.getAttribute("data-admin") !== null; }).length, 0);
eq("mais son bouton de retrait est réservé à l administrateur",
   stub.findAll(v.groupes, "BUTTON").filter(function (b) {
     return b.textContent === "×" && b.getAttribute("data-admin") !== null;
   }).length > 0, true);

/* Un rendu qui reconstruit son conteneur alors que rien n a changé vole le focus et
   avale les clics : le relevé tourne toutes les deux secondes. */
const avantRendu = v.groupes.children[0];
app.renderGroupes();
eq("un rendu identique ne reconstruit rien", v.groupes.children[0] === avantRendu, true);
const avantRegles = v.regles.children[0];
app.renderRegles();
eq("idem pour les règles", v.regles.children[0] === avantRegles, true);
app.setState({acces: Object.assign({}, accesGestion, {
  groupes: accesGestion.groupes.concat([G("neuf", "Tout neuf", [])])
}), peers: pairsGestion, server: {}, time: 2});
app.renderGroupes();
contient("mais un changement réel est bien redessiné", stub.textOf(v.groupes), "Tout neuf");

/* Un objet littéral hérite de son prototype : « constructor » et « toString » y valent
   une fonction, donc vrai. Un appareil portant ce nom n était jamais proposé. */
app.setState({
  acces: {groupes: [G("g", "Groupe", ["telephone"])], ressources: []},
  peers: [{name: "telephone"}, {name: "constructor"}, {name: "toString"}],
  server: {}, time: 3
});
app.ouvrirAjoutMembre({id: "g", libelle: "Groupe", appareils: ["telephone"]});
const proposes = stub.findAll(env.doc.getElementById("dlg-body"), "OPTION")
  .map(function (o) { return o.value; }).sort().join(",");
eq("un appareil au nom hérité du prototype est proposé", proposes, "constructor,toString");

/* --- le formulaire de regle ------------------------------------------------- */
app.setState({
  acces: {groupes: [G("admin", "Administration", ["telephone"])],
          ressources: [{id: "nas", libelle: "Le NAS", cible: "192.168.1.20"}]},
  peers: [{name: "telephone"}], server: {}, time: 4
});
app.ouvrirNouvelleRegle();
const corps = env.doc.getElementById("dlg-body");
function selParId(id) {
  return stub.findAll(corps, "SELECT").filter(function (s) { return s.id === id; })[0];
}
const dst = selParId("reg-dst");
/* Donner tous les droits a un groupe demandait quatre regles, a completer a chaque
   nouveau groupe. « Tout le trafic » les remplace, et reprend le mot employe a la
   creation d un appareil. */
eq("« Tout le trafic » est proposé en premier", dst.children[0].value, "tout");
eq("et porte le même libellé qu à la création d un appareil",
   dst.children[0].textContent, "Tout le trafic");

/* Un champ inopérant SANS explication adjacente se lit comme une panne : c est
   exactement ce qui a ete signale a l usage. */
const sens = selParId("reg-sens");
eq("le sens est inopérant hors destination « Groupe »", sens.disabled, true);
contient("et il dit pourquoi, juste en dessous de lui",
         stub.textOf(sens.parentNode.children[2]), "Groupe");
const ports = stub.findAll(corps, "INPUT").filter(function (i) { return i.id === "reg-ports"; })[0];
eq("les ports sont inopérants sans TCP ni UDP", ports.disabled, true);
contient("et le disent aussi", stub.textOf(ports.parentNode.children[2]), "TCP");

/* --- modifier plutot que ressaisir ----------------------------------------- */
/* Ajouter un seul port a une regle obligeait a la supprimer puis a retaper toute la
   liste de memoire. Le meme formulaire sert donc aux deux, pre-rempli. */
function inpDe(racine, id) {
  return stub.findAll(racine, "INPUT").filter(function (i) { return i.id === id; })[0];
}
function selDe(racine, id) {
  return stub.findAll(racine, "SELECT").filter(function (s) { return s.id === id; })[0];
}
const fluxMoon = F("p2", "res:moon", "MoonLight", "udp", "47998,47999", "aller");
app.setState({
  acces: {groupes: [G("gaming", "Gaming", ["telephone"], [fluxMoon])],
          ressources: [{id: "moon", libelle: "MoonLight", cible: "192.168.1.18"}]},
  peers: [{name: "telephone"}], server: {}, time: 5
});
app.ouvrirNouvelleRegle({groupe: {id: "gaming", libelle: "Gaming"}, flux: fluxMoon});
const modR = env.doc.getElementById("dlg-body");
eq("les ports existants sont repris tels quels", inpDe(modR, "reg-ports").value, "47998,47999");
eq("la destination est reprise", selDe(modR, "reg-dst").value, "res:moon");
eq("le protocole est repris", selDe(modR, "reg-proto").value, "udp");
/* Le protocole etant UDP, les ports doivent rester saisissables : un pre-remplissage
   suivi d un champ grise aurait efface la liste que l on vient justement de montrer. */
eq("et les ports restent modifiables", inpDe(modR, "reg-ports").disabled, false);
/* Changer « qui » ne modifie pas la regle : cela en fait une autre. Le serveur ignore
   ce champ, la fenetre ne doit donc pas laisser croire qu il agit. */
eq("le groupe source est verrouillé", selDe(modR, "reg-src").disabled, true);
eq("et montre le groupe de la règle", selDe(modR, "reg-src").value, "gaming");

/* Une creation ordinaire ne doit evidemment rien avoir herite de tout cela. */
app.ouvrirNouvelleRegle();
const neuve = env.doc.getElementById("dlg-body");
eq("une création part toujours de champs vides", inpDe(neuve, "reg-ports").value, "");
eq("et son groupe source reste choisissable", selDe(neuve, "reg-src").disabled, false);

/* addEventListener appelle son auditeur avec l objet Event en PREMIER argument. Depuis
   que ces fonctions prennent un parametre, un cablage direct leur livrait cet Event — un
   objet bien vrai — et le bouton « Nouvelle ressource » ouvrait « Modifier la ressource »,
   nom verrouille et vide, vers /api/ressources/undefined/edit. Le cablage est repare, mais
   c est la FONCTION qu on teste : elle seule resiste au prochain copier-coller. */
app.ouvrirNouvelleRessource({type: "click", target: {}});
const faux = env.doc.getElementById("dlg-body");
contient("un objet qui n est pas une ressource ouvre la création",
         stub.textOf(faux), "Créer la ressource");
eq("et son champ nom reste saisissable", inpDe(faux, "res-id").disabled, false);
app.ouvrirNouvelleRegle({type: "click", target: {}});
const fauxR = env.doc.getElementById("dlg-body");
contient("de même pour une règle", stub.textOf(fauxR), "Créer la règle");

/* La ressource : son nom est la cle citee par les regles. Le renommer les ferait
   pointer dans le vide, alors que changer son adresse les deplace toutes en silence. */
app.ouvrirNouvelleRessource({id: "moon", libelle: "MoonLight", cible: "192.168.1.18",
                             mac: "aa:bb:cc:dd:ee:ff"});
const modS = env.doc.getElementById("dlg-body");
/* Le reveil a distance : sans MAC retenue, figer l association ARP serait a refaire a
   chaque redemarrage du Pi, et le Wake-on-LAN ne marcherait qu une fois. */
eq("la MAC du réveil est reprise", inpDe(modS, "res-mac").value, "aa:bb:cc:dd:ee:ff");
eq("l adresse de la ressource est reprise", inpDe(modS, "res-ip").value, "192.168.1.18");
eq("le nom est montré mais verrouillé", inpDe(modS, "res-id").disabled, true);
contient("et la fenêtre annonce ce que la modification entraîne",
         stub.textOf(modS), "pointera vers la nouvelle adresse");

/* --- l appareil pris entre deux reglages contradictoires ------------------- */
/* Le mode de routage (ce que l appareil ENVOIE) et les regles de son groupe (ce que le Pi
   LAISSE PASSER) sont deux choses differentes. Quand « tout le trafic » rencontre « aucune
   regle Internet », les noms se resolvent et aucune page ne charge. Rien ne le disait.
   La reponse est calculee en bash, pour « wg-pi check » comme pour le panneau : deux
   implementations de la meme regle finiraient par diverger. */
app.setState({
  acces: {groupes: [], ressources: [],
          avertissements: [{appareil: "telephone", groupes: "« Administration »"}]},
  peers: [{name: "telephone"}, {name: "pc-salon"}], server: {}, time: 6
});
eq("l appareil signalé par le moteur est reconnu", app.appareilSansInternet("telephone"), true);
eq("et les autres ne le sont pas", app.appareilSansInternet("pc-salon"), false);
/* Un etat sans la cle du tout — installation ancienne, reponse tronquee — ne doit pas
   faire tomber le rendu de la liste des appareils. */
app.setState({acces: {groupes: [], ressources: []}, peers: [], server: {}, time: 7});
eq("une absence de la clé ne casse rien", app.appareilSansInternet("telephone"), false);

/* --- modeles de regles ----------------------------------------------------- */
/* L ORDRE est un piege reel et non une precaution de style : majSens vide le champ des
   ports des que le protocole n est ni TCP ni UDP. Un modele qui ecrirait les ports AVANT
   le protocole les perdrait en silence, et l utilisateur verrait un champ vide apres
   avoir clique. On rejoue ici le comportement exact de majSens. */
const champsFaux = {
  proto: {value: "any"}, ports: {value: ""}, lib: {value: ""},
  maj: function () {
    if (champsFaux.proto.value !== "tcp" && champsFaux.proto.value !== "udp") {
      champsFaux.ports.value = "";
    }
  }
};
const moon = app.MODELES_REGLE.filter(function (m) { return m.cle === "moonlight"; })[0];
eq("Moonlight annonce deux règles", app.remplirModele(moon, champsFaux), 2);
eq("le protocole est posé en premier", champsFaux.proto.value, "tcp");
eq("et les ports survivent à la remise à jour", champsFaux.ports.value, "47984,47989,48010");
/* Deux regles partagent un seul libelle : « Moonlight (TCP) » collerait « (TCP) » sur la
   regle UDP. C est le nom du service qui est propose. */
eq("un libellé est proposé", champsFaux.lib.value, "Moonlight");

/* Un libelle deja saisi par l utilisateur ne doit pas etre ecrase : c est le sien. */
const dejaRempli = {proto: {value: "any"}, ports: {value: ""}, lib: {value: "Le mien"},
                    maj: function () {}};
app.remplirModele(moon, dejaRempli);
eq("un libellé déjà saisi est respecté", dejaRempli.lib.value, "Le mien");

/* MAIS le libelle pose par un PRECEDENT clic de modele n est pas celui de l utilisateur.
   Signale a l usage : « si je change d'exemple ca change pas le libélé, ca garde le
   premier ». On creait donc une regle intitulee « NAS (partage Windows) » ouvrant les
   ports de Moonlight. L objet doit survivre d un clic au suivant pour s en souvenir : un
   objet neuf a chaque fois, ce qu il etait, ne se souvient de rien. */
const nas = app.MODELES_REGLE.filter(function (m) { return m.cle === "nas"; })[0];
const enchaine = {proto: {value: "any"}, ports: {value: ""}, lib: {value: ""},
                  maj: function () {}, libAuto: ""};
app.remplirModele(nas, enchaine);
eq("le premier modèle propose son libellé", enchaine.lib.value, "NAS (partage Windows)");
app.remplirModele(moon, enchaine);
eq("le second modèle remplace ce libellé", enchaine.lib.value, "Moonlight");
eq("et ses ports suivent aussi", enchaine.ports.value, "47984,47989,48010");
/* Et des que l utilisateur ecrit le sien, il est intouchable, meme apres un autre clic. */
enchaine.lib.value = "Mon salon";
app.remplirModele(nas, enchaine);
eq("un libellé saisi après un modèle reste intact", enchaine.lib.value, "Mon salon");

/* « -m multiport » ne va pas au-dela de 15 ports, une plage en comptant pour deux. Un
   modele qui depasserait serait refuse a l ecriture, donc au clic — et le defaut ne se
   verrait qu une fois chez l utilisateur. On le verifie ici, pas a l execution. */
function budgetPorts(p) {
  return p.split(",").reduce(function (s, x) { return s + (x.indexOf("-") >= 0 ? 2 : 1); }, 0);
}
const formePorts = /^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$/;
const fautifs = [];
app.MODELES_REGLE.forEach(function (m) {
  if (!m.cle || !m.titre || !m.aide || !m.regles.length) { fautifs.push(m.cle + ":vide"); }
  m.regles.forEach(function (g) {
    if (budgetPorts(g.ports) > 15) { fautifs.push(m.cle + ":budget"); }
    /* Aucune espace : la validation cote serveur n en tolere pas une seule. */
    if (!formePorts.test(g.ports)) { fautifs.push(m.cle + ":forme"); }
    /* Des ports n ont de sens qu avec TCP, UDP ou les deux : le moteur refuse les autres. */
    if (g.proto !== "tcp" && g.proto !== "udp" && g.proto !== "tcpudp") { fautifs.push(m.cle + ":proto"); }
    if (g.libelle.length > 60 || g.libelle.indexOf("|") >= 0) { fautifs.push(m.cle + ":libelle"); }
  });
});
eq("tous les modèles tiennent dans les limites du moteur", fautifs.join(","), "");

/* Un modele ne doit imposer ni destination ni sens. Lui seul sait si Moonlight vise le PC
   du salon ou toute la maison ; et le sens est verrouille selon la destination, parce que
   hors « groupe » le trafic de retour ne repasse pas par le VPN. */
const imposent = app.MODELES_REGLE.filter(function (m) {
  return m.regles.some(function (g) { return g.destination || g.dest || g.sens; });
});
eq("aucun modèle n impose de destination ni de sens", imposent.length, 0);

/* Les modeles a deux regles sont ceux dont les ports TCP et UDP different : c est la
   raison d etre de la route de lot. Si cette liste tombait a zero, la route serait morte
   sans que rien ne le signale. */
const aDeux = app.MODELES_REGLE.filter(function (m) { return m.regles.length > 1; });
eq("au moins un modèle pose deux règles", aDeux.length > 0, true);
const memesPorts = aDeux.filter(function (m) { return m.regles[0].ports === m.regles[1].ports; });
eq("et leurs deux listes de ports diffèrent vraiment", memesPorts.length, 0);

/* --- le cablage de la route de lot ----------------------------------------- */
/* Tout ce qui precede verifie les DONNEES des modeles. Le branchement, lui, n etait
   couvert par rien : quelle route part, avec quel corps, et dans quels cas. C est pourtant
   la decision la plus delicate du formulaire — un lot envoye a tort cree une regle que
   l utilisateur n a pas vue, un lot non envoye lui en fait creer deux a la main. */
function boutonTexte(racine, libelle) {
  return stub.findAll(racine, "BUTTON").filter(function (x) {
    return stub.textOf(x) === libelle;
  })[0];
}
function soumettre(modele, retouche) {
  env.requetes.length = 0;
  env.etat.reponse = {status: 200, data: {ok: true}};
  app.setState({
    acces: {groupes: [G("gaming", "Gaming", ["telephone"])],
            ressources: [{id: "moon", libelle: "MoonLight", cible: "192.168.1.18"}]},
    peers: [{name: "telephone"}], server: {}, time: 9
  });
  app.ouvrirNouvelleRegle();
  const b = env.doc.getElementById("dlg-body");
  const form = stub.findAll(b, "FORM")[0];
  selDe(b, "reg-dst").value = "res:moon";
  form.dispatchEvent({type: "change", target: selDe(b, "reg-dst")});
  if (modele) {
    /* On clique le bouton du modele, par son libelle : c est ce que fait l utilisateur. */
    const bouton = boutonTexte(b, modele);
    if (!bouton) { return {erreur: "bouton « " + modele + " » introuvable"}; }
    bouton.dispatchEvent({type: "click"});
  }
  if (retouche) { retouche(b); }
  form.dispatchEvent({type: "submit"});
  return env.requetes[0] || {erreur: "aucune requete"};
}

/* Moonlight : deux regles, des ports differents par protocole. Le lot doit partir. */
const rLot = soumettre("Moonlight");
eq("le modele a deux regles part vers la route de lot", rLot.url, "/api/regles/lot");
eq("en POST", rLot.method, "POST");
eq("et le corps porte les deux regles", (rLot.body && rLot.body.regles || []).length, 2);
eq("la premiere en TCP", (rLot.body && rLot.body.regles || [{}])[0].proto, "tcp");
eq("la seconde en UDP", (rLot.body && rLot.body.regles || [{}, {}])[1].proto, "udp");
eq("les deux visent la meme destination",
   (rLot.body && rLot.body.regles || [{}, {}]).map(function (x) { return x.destination; }).join(","),
   "res:moon,res:moon");
/* Le jeton anti-CSRF part avec : sans lui le serveur refuse, et la fenetre resterait
   ouverte sur une erreur que personne ne saurait interpreter. */
eq("le jeton anti-CSRF accompagne la requete",
   typeof (rLot.entetes && rLot.entetes["X-CSRF-Token"]), "string");

/* Un modele a UNE seule regle passe par la route ordinaire : envoyer un lot d un element
   marcherait, mais la route ordinaire rend un message plus juste. */
const rSimple = soumettre("NAS");
eq("un modele a une seule regle passe par la route ordinaire", rSimple.url, "/api/regles");
eq("et son corps est une regle, pas une liste", rSimple.body && rSimple.body.regles, undefined);
eq("avec le protocole du modele", rSimple.body && rSimple.body.proto, "tcp");

/* Sans modele du tout : route ordinaire aussi. */
const rRien = soumettre(null);
eq("sans modele, route ordinaire", rRien.url, "/api/regles");

/* Retoucher la premiere ligne ne doit PAS faire disparaitre la seconde : elle est a
   l ecran, l utilisateur la voit et peut la retirer lui-meme s il n en veut pas. C est
   tout l interet de lignes visibles plutot que de regles filles implicites — avant, une
   retouche annulait en silence une regle que l utilisateur croyait avoir demandee. */
const rRetouchePorts = soumettre("Moonlight", function (b) {
  inpDe(b, "reg-ports").value = "47984";
});
eq("des ports retouches gardent la seconde regle", rRetouchePorts.url, "/api/regles/lot");
eq("la premiere porte les ports de l utilisateur",
   (rRetouchePorts.body && rRetouchePorts.body.regles || [{}])[0].ports, "47984");
eq("et la seconde ceux du modele",
   (rRetouchePorts.body && rRetouchePorts.body.regles || [{}, {}])[1].ports, "47998-48000,48010");

const rRetoucheProto = soumettre("Moonlight", function (b) {
  selDe(b, "reg-proto").value = "icmp";
});
eq("un protocole retouche garde aussi la seconde", rRetoucheProto.url, "/api/regles/lot");
eq("et la premiere suit le choix de l utilisateur",
   (rRetoucheProto.body && rRetoucheProto.body.regles || [{}])[0].proto, "icmp");

/* Et il peut la retirer : le lot redevient une regle simple. */
const rRetiree = soumettre("Moonlight", function (b) {
  boutonTexte(b, "Retirer cette règle").dispatchEvent({type: "click"});
});
eq("retirer la seconde ligne redonne une regle simple", rRetiree.url, "/api/regles");

/* --- le « + » : plusieurs regles dans UNE fenetre -------------------------- */
/* La demande d origine : « configurer les 2 direct dans la meme modal pour eviter de
   valider 1 puis reouvrir pour le 2eme ». */
const rPlus = soumettre(null, function (b) {
  boutonTexte(b, "+ Ajouter une règle").dispatchEvent({type: "click"});
  selDe(b, "reg-proto").value = "tcp";
  inpDe(b, "reg-ports").value = "8080";
  selDe(b, "reg-proto-sup-1").value = "udp";
  inpDe(b, "reg-ports-sup-1").value = "9000-9001";
});
eq("une ligne ajoutee a la main part en lot", rPlus.url, "/api/regles/lot");
eq("avec les deux regles", (rPlus.body && rPlus.body.regles || []).length, 2);
eq("la premiere telle que saisie",
   (rPlus.body && rPlus.body.regles || [{}])[0].proto + " " + (rPlus.body.regles[0].ports),
   "tcp 8080");
eq("la seconde telle que saisie",
   (rPlus.body && rPlus.body.regles || [{}, {}])[1].proto + " " + (rPlus.body.regles[1].ports),
   "udp 9000-9001");
/* Le groupe, la destination et le sens sont partages : une regle vers une AUTRE
   destination est une autre regle, pas une variante de celle-ci. */
eq("les deux partagent la destination",
   (rPlus.body && rPlus.body.regles || [{}, {}]).map(function (x) { return x.destination; }).join(","),
   "res:moon,res:moon");
eq("et le groupe source",
   (rPlus.body && rPlus.body.regles || [{}, {}]).map(function (x) { return x.source; }).join(","),
   "gaming,gaming");

/* Les ports d une ligne ajoutee suivent la meme regle que ceux de la premiere : ICMP n a
   pas de ports, et les laisser saisissables ferait croire le contraire. */
const rSupIcmp = soumettre(null, function (b) {
  boutonTexte(b, "+ Ajouter une règle").dispatchEvent({type: "click"});
  const p = selDe(b, "reg-proto-sup-1");
  inpDe(b, "reg-ports-sup-1").value = "9000";
  p.value = "icmp";
  p.dispatchEvent({type: "change"});
});
eq("un protocole sans ports vide la ligne ajoutee",
   (rSupIcmp.body && rSupIcmp.body.regles || [{}, {}])[1].ports, "");

/* Quatre regles au plus : c est la borne de la route de lot. La fenetre s arrete donc la
   plutot que de laisser envoyer un lot que le serveur refusera. */
app.setState({
  acces: {groupes: [G("gaming", "Gaming", ["telephone"])], ressources: []},
  peers: [{name: "telephone"}], server: {}, time: 11
});
app.ouvrirNouvelleRegle();
const bMax = env.doc.getElementById("dlg-body");
const plusBtn = boutonTexte(bMax, "+ Ajouter une règle");
eq("le + est disponible au depart", plusBtn.disabled, false);
plusBtn.dispatchEvent({type: "click"});
plusBtn.dispatchEvent({type: "click"});
plusBtn.dispatchEvent({type: "click"});
eq("il se desactive a la quatrieme regle", plusBtn.disabled, true);
eq("et il le dit", stub.textOf(bMax).indexOf("Quatre règles au plus") >= 0, true);
eq("trois lignes ont bien ete ajoutees",
   stub.findAll(bMax, "SELECT").filter(function (s) {
     return String(s.id).indexOf("reg-proto-sup-") === 0;
   }).length, 3);

/* Un libelle que l utilisateur a ecrit lui-meme doit se retrouver sur les DEUX regles du
   lot : sinon la seconde porterait un nom qu il n a pas choisi. */
const rLibelle = soumettre("Moonlight", function (b) {
  inpDe(b, "reg-lib").value = "Mon salon";
});
eq("un libelle saisi reste le lot", rLibelle.url, "/api/regles/lot");
eq("et il habille les deux regles",
   (rLibelle.body && rLibelle.body.regles || []).map(function (x) { return x.libelle; }).join("|"),
   "Mon salon|Mon salon");

/* Et le modele a deux protocoles sur les MEMES ports (« Jeu en reseau ») n est PAS un lot :
   une seule regle en tcpudp suffit, et le moteur en pose deux lignes. */
const rJeu = soumettre("Jeu en réseau");
eq("le modele a deux protocoles tient en une regle", rJeu.url, "/api/regles");
eq("portee par le protocole double", rJeu.body && rJeu.body.proto, "tcpudp");
eq("et ses ports survivent au verrouillage des champs",
   rJeu.body && rJeu.body.ports, "27015,27036");

/* --- le bandeau de confirmation ne doit pas se reconstruire a chaque releve --- */
/* Le releve tourne toutes les deux secondes. Reconstruire ce bandeau a chaque fois vole
   le focus du clavier et, surtout, remet a zero le « disabled » qu envoiUnique vient de
   poser sur « Tout va bien, confirmer » : la garde anti-double-envoi etait annulee par le
   releve suivant. */
function confirmBox(mode, confirme) {
  app.setState({acces: {mode: mode, noyau: mode === "filtre" ? "actif" : "inactif",
                        confirme: confirme, groupes: [], ressources: [], ecoute: []},
                peers: [], server: {}, time: 20});
  app.renderConfirmation();
  return env.doc.getElementById("acc-confirm");
}
const bc1 = confirmBox("filtre", false);
const bouton1 = stub.findAll(bc1, "BUTTON")[0];
eq("le bandeau porte son bouton", bouton1 && stub.textOf(bouton1), "Tout va bien, confirmer");
eq("et il est visible", bc1.hidden, false);
/* Deuxieme releve, etat IDENTIQUE : le meme noeud doit survivre. */
bouton1.disabled = true;
confirmBox("filtre", false);
const bouton2 = stub.findAll(env.doc.getElementById("acc-confirm"), "BUTTON")[0];
eq("un releve a l identique ne reconstruit pas le bouton", bouton2 === bouton1, true);
eq("la garde anti-double-envoi survit au releve", bouton2.disabled, true);
/* Et un changement REEL doit bien passer : sinon la garde cacherait l information. */
const bc3 = confirmBox("filtre", true);
eq("une fois confirme, le bandeau disparait", bc3.hidden, true);
eq("et il est vide", stub.findAll(bc3, "BUTTON").length, 0);
const bc4 = confirmBox("filtre", false);
eq("et il revient si la confirmation retombe", bc4.hidden, false);
eq("avec un bouton neuf, actif", stub.findAll(bc4, "BUTTON")[0].disabled, false);
/* Hors filtrage, il n a rien a dire. */
eq("hors filtrage : masque", confirmBox("ouvert", false).hidden, true);

/* --- « Tout le trafic » est un acces ENTRANT vers chaque appareil ----------- */
/* Le moteur traduit « tout » en « -d 0.0.0.0/0 », qui contient le reseau du tunnel : une
   telle regle laisse donc ce groupe joindre CHAQUE appareil du VPN, sur tous les ports.
   fluxEntrants ne regardait que les destinations « groupe », et la fiche de chaque
   appareil affirmait « Aucun autre appareil n a de regle vers lui ». */
const accesTout = {
  mode: "filtre", noyau: "actif", ressources: [], ecoute: [],
  groupes: [G("admin", "Administration", ["pc-salon"], [F("p1", "tout", "Tout le trafic")]),
            G("fam", "Famille", ["telephone"], [])]
};
app.setState({acces: accesTout,
              peers: [P("telephone", ["fam"]), P("pc-salon", ["admin"])],
              server: {}, time: 40});
const entTel = app.fluxEntrants("telephone");
eq("« tout le trafic » est un acces entrant", entTel.length, 1);
eq("et il nomme le groupe qui l a", entTel[0] && entTel[0].groupe.id, "admin");
/* Un appareil DU groupe ne se joint pas lui-meme : l annoncer serait du bruit. */
eq("un appareil du groupe ne se compte pas", app.fluxEntrants("pc-salon").length, 0);
/* Et les destinations qui ne sont ni « tout » ni un groupe restent hors sujet. */
const accesRes = {
  mode: "filtre", noyau: "actif", ecoute: [],
  ressources: [{id: "nas", libelle: "NAS", cible: "192.168.1.20"}],
  groupes: [G("admin", "Administration", ["pc-salon"],
              [F("p1", "res:nas", "NAS"), F("p2", "internet", "Internet")])]
};
app.setState({acces: accesRes,
              peers: [P("telephone", []), P("pc-salon", ["admin"])],
              server: {}, time: 41});
eq("une ressource n est pas un acces entrant", app.fluxEntrants("telephone").length, 0);

/* --- le focus de la carte ne survit pas a l appareil vise ------------------- */
/* Le focus retient une cle. Si l appareil vise disparait, plus aucun noeud ne recoit la
   classe « sel » : le CSS laisse TOUTE la carte a 12 % d opacite, sans un mot, et il n y a
   meme plus rien a cliquer pour en sortir. */
const pairsFocus = [P("telephone", ["fam"], 0, 0, true, true), P("pc-salon", ["fam"], 0, 0, true, true)];
const accesFocus = {
  mode: "filtre", noyau: "actif", ressources: [], ecoute: [],
  groupes: [G("fam", "Famille", ["telephone", "pc-salon"], [F("p1", "internet", "Internet")])]
};
renderCarte(accesFocus, pairsFocus);
let svgF = stub.findAll(env.doc.getElementById("map-box"), "SVG")[0];
app.mapClick(noeudCarte(svgF, "data-dev", "telephone"));
eq("le focus est pose", app.mapFocusKey(), "dev:telephone");
/* L appareil vise disparait — supprime, ou simplement renomme. On redessine SANS passer
   par renderCarte, qui commence par remettre le focus a zero : sinon l assertion
   passerait quoi qu il arrive. */
app.setState({acces: accesFocus, peers: [P("pc-salon", ["fam"], 0, 0, true, true)],
              server: {}, time: 42});
app.renderMap();
eq("un focus orphelin est oublie", app.mapFocusKey(), null);
svgF = stub.findAll(env.doc.getElementById("map-box"), "SVG")[0];
eq("et la carte n est plus estompee", String(svgF.getAttribute("class")).indexOf("focus"), -1);
/* Un focus qui designe encore quelque chose survit, lui. */
renderCarte(accesFocus, pairsFocus);
svgF = stub.findAll(env.doc.getElementById("map-box"), "SVG")[0];
app.mapClick(noeudCarte(svgF, "data-dev", "telephone"));
/* Sans passer par renderCarte, qui commence par remettre le focus a zero. */
app.setState({acces: accesFocus, peers: pairsFocus, server: {}, time: 43});
app.renderMap();
eq("un focus encore valide est garde", app.mapFocusKey(), "dev:telephone");
app.mapReset();

/* --- le bandeau de redemarrage --------------------------------------------- */
/* « Un redemarrage est demande » ne se voyait que dans la fenetre « Mises a jour », qu il
   faut ouvrir expres. Il voyage maintenant avec l etat, donc il se dit sur tous les
   ecrans. Signale depuis l usage reel : l utilisateur a du le decouvrir avec « wg-pi
   check » apres avoir installe ses mises a jour. */
function etatAvecReboot(reboot) {
  app.setState({reboot: reboot, peers: [], server: {}, time: 30,
                acces: {mode: "ouvert", noyau: "inactif", groupes: [], ressources: [], ecoute: []}});
  app.renderRedemarrage();
  return env.doc.getElementById("reboot-note");
}
const rb1 = etatAvecReboot(true);
eq("le bandeau se montre", rb1.hidden, false);
contient("et il dit ce qui se passe", rb1.textContent, "Un redémarrage du Pi est demandé");
contient("et pourquoi cela compte", rb1.textContent, "ancienne version");
/* Le panneau savait le DIRE mais pas le FAIRE : il fallait un terminal. */
const btnReboot = boutonTexte(rb1, "Redémarrer le Pi");
eq("le bandeau porte le bouton qui repare", !!btnReboot, true);
/* Marque « data-admin » : la regle de masquage du theme le retire pour un compte de
   consultation, que la route refuserait de toute facon. */
eq("et il est marque reserve a l administrateur",
   btnReboot && btnReboot.getAttribute("data-admin"), "");
/* Un clic OUVRE une confirmation, il ne redemarre pas : un bandeau permanent qui
   redemarrerait au premier clic de travers serait un piege. */
env.requetes.length = 0;
env.etat.reponse = {status: 200, data: {ok: true}};
btnReboot.dispatchEvent({type: "click"});
eq("un clic ne redemarre pas tout de suite", env.requetes.length, 0);
const dlgReboot = env.doc.getElementById("dlg-body");
/* Le titre vit hors de #dlg-body, que le faux DOM est seul a materialiser : on verifie
   donc la confirmation sur son CORPS, qui est ce que l utilisateur lit avant de cliquer. */
contient("il demande confirmation", stub.textOf(dlgReboot), "VPN sera coupé");
contient("et dit que le panneau revient", stub.textOf(dlgReboot), "reviendra tout seul");
const formReboot = stub.findAll(dlgReboot, "FORM")[0];
formReboot.dispatchEvent({type: "submit"});
eq("la confirmation poste vers la route de redemarrage",
   (env.requetes[0] || {}).url, "/api/reboot");
eq("en POST", (env.requetes[0] || {}).method, "POST");
eq("avec le jeton anti-CSRF",
   typeof ((env.requetes[0] || {}).entetes || {})["X-CSRF-Token"], "string");
/* Un second envoi pendant que le premier est en vol dupliquerait la demande. */
env.requetes.length = 0;
formReboot.dispatchEvent({type: "submit"});
eq("et un second envoi est avale", env.requetes.length, 0);
/* Un releve a l identique ne doit pas le reecrire : « role=status » est relu par un lecteur
   d ecran a chaque modification, et le releve tourne toutes les deux secondes. */
rb1.textContent = rb1.textContent + "|temoin";
etatAvecReboot(true);
eq("un releve a l identique ne le reecrit pas",
   env.doc.getElementById("reboot-note").textContent.indexOf("|temoin") >= 0, true);
/* Et il disparait quand le redemarrage a eu lieu. */
const rb2 = etatAvecReboot(false);
eq("apres le redemarrage, il se cache", rb2.hidden, true);
eq("et il est vide", rb2.textContent, "");
const rb3 = etatAvecReboot(true);
eq("et il revient si un nouveau paquet le demande", rb3.hidden, false);
/* Un etat sans la cle du tout — un « wg-pi json » d une version anterieure, pendant une
   mise a jour — ne doit pas afficher le bandeau. */
app.setState({peers: [], server: {}, time: 31,
              acces: {mode: "ouvert", noyau: "inactif", groupes: [], ressources: [], ecoute: []}});
app.renderRedemarrage();
eq("une cle absente ne reveille pas le bandeau",
   env.doc.getElementById("reboot-note").hidden, true);

/* --- le titre de l onglet du navigateur ------------------------------------- */
/* Il annoncait « Appareils · wg-pi » quelle que soit la section : deux fenetres ouvertes
   sur deux sections etaient indiscernables dans la barre d onglets, dans l historique et
   dans un favori. */
const TITRES = {app: "Appareils · wg-pi", grp: "Groupes · wg-pi", acc: "Accès · wg-pi",
                map: "Carte · wg-pi", srv: "Serveur · wg-pi"};
Object.keys(TITRES).forEach(function (cle) {
  app.montrerOnglet(cle);
  eq("onglet " + cle + " : le titre suit", env.doc.title, TITRES[cle]);
});
/* Une cle inconnue — un localStorage abime — retombe sur la premiere section, titre compris. */
app.montrerOnglet("nimporte-quoi");
eq("une section inconnue retombe sur Appareils", env.doc.title, "Appareils · wg-pi");

/* --- les trois cas qui demandent d ATTENDRE une reponse ---------------------- */
/* Tout ce qui precede est synchrone. Ici le code sous test traite une REPONSE : il faut
   donc laisser tourner les microtaches entre chaque etape. Le resume final part a la fin
   de la chaine, sinon il serait affiche avant que ces cas soient joues. */
function tic() { return new Promise(function (r) { setTimeout(r, 0); }); }
function etatServeur(time, mode, reboot) {
  return {time: time, peers: [], server: {}, role: "admin", reboot: !!reboot,
          acces: {mode: mode, noyau: mode === "filtre" ? "actif" : "inactif",
                  confirme: true, groupes: [], ressources: [], ecoute: []}};
}
function releve(time, mode, reboot) {
  env.etat.reponse = {status: 200, data: etatServeur(time, mode, reboot)};
  app.poll();
  return tic();
}

/* Le stub pose « document.hidden = true » pour que la boucle du panneau sorte toute
   seule au chargement. Ici on veut justement qu elle travaille. */
env.doc.hidden = false;

Promise.resolve()
  /* [defaut] Un releve dont l horodatage a RECULE etait jete, et tous les suivants avec
     lui pendant toute la duree du recul : le panneau se figeait en affirmant « Filtrage
     actif » alors que le serveur disait le contraire. Rien ne le signalait, la requete
     ayant reussi. L horloge d un Pi sans pile recule a chaque demarrage. */
  .then(function () { return releve(1000, "filtre"); })
  .then(function () {
    eq("le premier releve est applique",
       env.doc.getElementById("acc-state").textContent, "Filtrage actif");
    return releve(400, "ouvert");
  })
  .then(function () {
    eq("un releve dont l horloge a recule est applique quand meme",
       env.doc.getElementById("acc-state").textContent, "Aucun cloisonnement");
    eq("et aucune alerte reseau n est levee", env.doc.getElementById("alert").hidden, true);
    /* Et l horloge qui repart en avant ne doit evidemment rien casser. */
    return releve(1200, "filtre");
  })
  .then(function () {
    eq("l horloge qui repart en avant passe aussi",
       env.doc.getElementById("acc-state").textContent, "Filtrage actif");
  })
  /* Le bandeau de redemarrage, par le CHEMIN REEL : le releve. Les cas plus haut
     appellent renderRedemarrage a la main, ce qui laissait son branchement dans
     update() sans aucune couverture — le retirer ne faisait rien tomber. */
  .then(function () {
    env.doc.getElementById("reboot-note").hidden = true;
    env.doc.getElementById("reboot-note").textContent = "";
    return releve(1300, "filtre", true);
  })
  .then(function () {
    const note = env.doc.getElementById("reboot-note");
    eq("un releve qui annonce un redemarrage montre le bandeau", note.hidden, false);
    contient("et il dit quoi faire", note.textContent, "redémarrage du Pi");
    return releve(1400, "filtre", false);
  })
  .then(function () {
    eq("et le releve suivant le retire", env.doc.getElementById("reboot-note").hidden, true);
  })
  /* [defaut] La fenetre « Mises a jour » n avait aucune garde d envoi unique : un double
     clic lancait la mise a jour, puis affichait en rouge qu elle avait echoue — la route
     refusant une seconde unite systemd du meme nom. Le pire des messages possibles. */
  .then(function () {
    env.etat.reponse = {status: 200, data: {wgpi: "1.8.0", maj_etat: "neuf",
      maj_version: "1.9.0", wireguard: "1.0.20210914", paquets: 0, auto: "actif",
      admin: true, par_vpn: false, reboot: false}};
    app.ouvrirReglages();
    return tic();
  })
  .then(function () {
    const corps = env.doc.getElementById("dlg-body");
    const maj = boutonTexte(corps, "Mettre wg-pi à jour");
    eq("le bouton de mise a jour est propose", !!maj, true);
    if (!maj) { return; }
    env.requetes.length = 0;
    maj.dispatchEvent({type: "click"});
    maj.dispatchEvent({type: "click"});
    maj.dispatchEvent({type: "click"});
    const posts = env.requetes.filter(function (r) { return r.url === "/api/update"; });
    eq("trois clics ne lancent qu une seule mise a jour", posts.length, 1);
    eq("et le bouton est desactive des le premier", maj.disabled, true);
    return tic();
  })
  .then(function () {
    /* Le second bouton de la meme fenetre, celui des mises a jour automatiques. */
    env.etat.reponse = {status: 200, data: {wgpi: "1.8.0", maj_etat: "a_jour",
      wireguard: "1.0", paquets: 0, auto: "arrete", admin: true,
      par_vpn: false, reboot: false}};
    app.ouvrirReglages();
    return tic();
  })
  .then(function () {
    const corps = env.doc.getElementById("dlg-body");
    const bascule = boutonTexte(corps, "Activer les mises à jour auto");
    eq("la bascule des mises a jour auto est proposee", !!bascule, true);
    if (!bascule) { return; }
    env.requetes.length = 0;
    bascule.dispatchEvent({type: "click"});
    bascule.dispatchEvent({type: "click"});
    const posts = env.requetes.filter(function (r) { return r.url === "/api/auto-updates"; });
    eq("deux clics ne basculent qu une fois", posts.length, 1);
    eq("et la bascule est desactivee des le premier", bascule.disabled, true);
  })
  /* [defaut] Les deux .then appelaient closeDialog() — et pour l un ouvrirReglages() —
     sans verifier que c etait encore LEUR fenetre. Partout ailleurs dans le panneau ce
     geste est garde par « if (f.isConnected) », dix fois. openDialog commence par vider le
     corps du dialogue : rouvrir « Mises a jour » depuis un .then effacait donc la fenetre
     que l utilisateur venait d ouvrir, et le formulaire qu il y remplissait. */
  .then(function () {
    env.etat.reponse = {status: 200, data: {wgpi: "1.8.0", maj_etat: "neuf",
      maj_version: "1.9.0", wireguard: "1.0", paquets: 0, auto: "actif",
      admin: true, par_vpn: false, reboot: false}};
    app.ouvrirReglages();
    return tic();
  })
  .then(function () {
    /* C est la BASCULE qui remplace la fenetre : son .then rouvre « Mises a jour », et
       openDialog commence par VIDER le corps du dialogue — quel qu il soit. Le bouton de
       mise a jour, lui, ne fait que fermer. */
    const bascule = boutonTexte(env.doc.getElementById("dlg-body"), "Arrêter les mises à jour auto");
    if (!bascule) { ko("la bascule a disparu"); return; }
    /* La reponse n arrive pas tout de suite : l utilisateur ouvre autre chose entre-temps. */
    let resoudre;
    const vrai = global.fetch;
    global.fetch = function () {
      return new Promise(function (r) {
        resoudre = function () { r({ok: true, status: 200, json: function () { return Promise.resolve({ok: true}); }}); };
      });
    };
    bascule.dispatchEvent({type: "click"});
    global.fetch = vrai;
    /* L utilisateur ouvre SA fenetre pendant l envoi. */
    app.ouvrirNouvelleRessource();
    const avant = stub.textOf(env.doc.getElementById("dlg-body"));
    eq("la fenetre de l utilisateur est bien la",
       avant.indexOf("dresse") >= 0, true);
    if (resoudre) { resoudre(); }
    return tic().then(tic);
  })
  .then(function () {
    const corps = stub.textOf(env.doc.getElementById("dlg-body"));
    eq("elle n a pas ete remplacee par Mises a jour", corps.indexOf("Paquets du système"), -1);
    eq("et elle est toujours la", corps.indexOf("dresse") >= 0, true);
  })
  .then(function () {
    console.log("");
    console.log("  " + pass + " réussi(s), " + fail + " échoué(s)");
    process.exit(fail === 0 ? 0 : 1);
  })
  .catch(function (e) {
    console.log("  KO   la chaine asynchrone leve : " + (e && e.stack ? e.stack : e));
    process.exit(1);
  });
