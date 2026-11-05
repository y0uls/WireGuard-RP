/* Stub de DOM minimal, juste assez pour EXÉCUTER le JavaScript du panneau sous node.
   Le but n'est pas de simuler un navigateur, mais de faire tourner le code : une variable
   non déclarée lève alors une ReferenceError, ce que « node --check » ne voit pas.
   document.hidden vaut true, donc la boucle de rafraîchissement sort immédiatement et
   aucune requête réseau n'est tentée. */
"use strict";

function makeEl(tag) {
  var e = {
    tagName: String(tag || "div").toUpperCase(),
    className: "", title: "", id: "", type: "",
    _text: "",
    innerHTML: "", hidden: false, value: "",
    children: [], parentNode: null, attributes: {},
    style: {}, dataset: {},
    classList: {
      add: function () {}, remove: function () {}, toggle: function () {}, contains: function () { return false; }
    },
    appendChild: function (c) { c.parentNode = e; e.children.push(c); return c; },
    append: function () {
      for (var i = 0; i < arguments.length; i++) {
        var a = arguments[i];
        if (a && typeof a === "object") { e.appendChild(a); } else { e._text += String(a); }
      }
    },
    insertBefore: function (c) { return e.appendChild(c); },
    removeChild: function (c) { e.children = e.children.filter(function (x) { return x !== c; }); return c; },
    remove: function () { if (e.parentNode) { e.parentNode.removeChild(e); } },
    setAttribute: function (k, v) { e.attributes[k] = String(v); },
    getAttribute: function (k) { return Object.prototype.hasOwnProperty.call(e.attributes, k) ? e.attributes[k] : null; },
    removeAttribute: function (k) { delete e.attributes[k]; },
    addEventListener: function () {},
    removeEventListener: function () {},
    insertAdjacentHTML: function () {},
    /* Resout les selecteurs d attribut de la forme [data-xxx], les seuls utilises
       par le code teste. Suffisant pour rendre le mode focus de la carte verifiable. */
    querySelectorAll: function (sel) {
      var m = /^\[([-a-z]+)\]$/.exec(String(sel || ""));
      if (!m) { return []; }
      var attr = m[1], out = [];
      (function walk(n) {
        (n.children || []).forEach(function (c) {
          if (c.getAttribute && c.getAttribute(attr) != null) { out.push(c); }
          walk(c);
        });
      })(e);
      return out;
    },
    querySelector: function (sel) { return e.querySelectorAll(sel)[0] || null; },
    closest: function () { return null; },
    focus: function () {}, select: function () {}, click: function () {},
    showModal: function () {}, close: function () {}, scrollIntoView: function () {}
  };
  /* textContent est un accesseur, et non un simple champ : dans un vrai DOM, lui
     affecter une valeur VIDE LE SOUS-ARBRE. Sans cela, un rendu qui commence par
     « box.textContent = "" » laisserait les anciens noeuds en place, et un test lirait
     l ancien rendu en croyant lire le nouveau. */
  Object.defineProperty(e, "textContent", {
    get: function () {
      var t = e._text;
      e.children.forEach(function (c) { t += c.textContent; });
      return t;
    },
    set: function (v) {
      e.children.forEach(function (c) { c.parentNode = null; });
      e.children = [];
      e._text = String(v == null ? "" : v);
    },
    enumerable: true, configurable: true
  });
  return e;
}

/* Texte rendu par un sous-arbre, pour les assertions. */
function textOf(e) {
  if (!e) { return ""; }
  return e.textContent || "";
}

/* Tous les descendants dont le nom de balise correspond. */
function findAll(e, tag) {
  var out = [];
  (function walk(n) {
    (n.children || []).forEach(function (c) {
      if (c.tagName === tag.toUpperCase()) { out.push(c); }
      walk(c);
    });
  })(e);
  return out;
}

/* Pose une valeur sur l objet global, quelle que soit la version de node.
   Depuis node 21, « navigator » existe deja et n a qu un accesseur en lecture : une
   simple affectation leve « Cannot set property navigator ». On passe donc par
   defineProperty, et on renonce en silence si meme cela est refuse — le code teste
   s accommode de la valeur native. */
function poser(nom, valeur) {
  try {
    global[nom] = valeur;
    if (global[nom] === valeur) { return true; }
  } catch (e) { /* propriete en lecture seule : on tente defineProperty */ }
  try {
    Object.defineProperty(global, nom, {value: valeur, writable: true, configurable: true});
    return true;
  } catch (e) {
    return false;
  }
}

function install(ids) {
  var registry = Object.create(null);
  (ids || []).forEach(function (id) { registry[id] = makeEl("div"); registry[id].id = id; });
  var doc = {
    documentElement: makeEl("html"),
    body: makeEl("body"),
    hidden: true,
    /* Cree l element a la demande : le code du panneau manipule des dizaines
       d identifiants, et rendre null ferait echouer son initialisation avant meme
       d arriver au rendu que l on veut tester. */
    getElementById: function (id) {
      if (!registry[id]) { registry[id] = makeEl("div"); registry[id].id = id; }
      return registry[id];
    },
    createElement: makeEl,
    createElementNS: function (ns, tag) { return makeEl(tag); },
    querySelectorAll: function () { return []; },
    querySelector: function () { return null; },
    addEventListener: function () {},
    removeEventListener: function () {}
  };
  poser("document", doc);
  const fenetre = {
    addEventListener: function () {}, removeEventListener: function () {},
    matchMedia: function () { return {matches: false, addEventListener: function () {}, addListener: function () {}}; },
    location: {href: "", pathname: "/", reload: function () {}},
    navigator: {clipboard: {writeText: function () { return Promise.resolve(); }}},
    setTimeout: setTimeout, setInterval: function () { return 0; }
  };
  poser("window", fenetre);
  poser("location", fenetre.location);
  poser("navigator", fenetre.navigator);
  poser("localStorage", {
    _d: Object.create(null),
    getItem: function (k) { return Object.prototype.hasOwnProperty.call(this._d, k) ? this._d[k] : null; },
    setItem: function (k, v) { this._d[k] = String(v); },
    removeItem: function (k) { delete this._d[k]; }
  });
  poser("fetch", function () { return Promise.reject(new Error("aucun reseau dans les tests")); });
  /* setInterval neutralise : le code du panneau en installe un au chargement. */
  poser("setInterval", function () { return 0; });
  return {doc: doc, registry: registry};
}

module.exports = {install: install, makeEl: makeEl, textOf: textOf, findAll: findAll};
