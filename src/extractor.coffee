cheerio = require("cheerio")
_ = require("underscore")

cleaner = require("./cleaner")
stopwords = require("./stopwords")
formatter = require("./formatter")

module.exports = extractor = (html, language) ->
  doc = cheerio.load(html)
  lng = language || lang(doc)

  {
    title: title(doc)
    favicon: favicon(doc)
    description: description(doc)
    keywords: keywords(doc)
    lang: lng
    canonicalLink: canonicalLink(doc)
    tags: extractTags(doc)
    text: text(doc, lng)
  }

# Grab the 'main' text chunk of an html document
text = (doc, lang) ->
  # Pipeline Step 1: Clean the doc
  cleaner(doc)

  # Pipeline Step 2: Find the doc node with the best ext
  topNode = calculateBestNode(doc, lang)

  if topNode
    # Pipeline Step 3: Remove any trashy/junky nodes
    topNode = postCleanup(doc, topNode, lang)
    # Pipeline Step 4: Extract text from the html
    formatter(doc, topNode, lang)
  else
    ""

# Grab the title of an html doc (excluding junk)
title = (doc) ->
  titleElement = doc("title")
  return null unless titleElement

  titleText = titleElement.text()

  usedDelimeter = false
  _.each ["|", " - ", "»", ":"], (c) ->
    if titleText.indexOf(c) >= 0 && !usedDelimeter
      titleText = biggestTitleChunk(titleText, c)
      usedDelimeter = true

  titleText.replace(/�/g, "").trim()

# Find the biggest chunk of text in the title
biggestTitleChunk = (title, splitter) ->
  largeTextLength = 0
  largeTextIndex = 0

  titlePieces = title.split(splitter)

  # find the largest substring
  _.each titlePieces, (piece, i)->
    if piece.length > largeTextLength
      largeTextLength = piece.length
      largeTextIndex = i

  titlePieces[largeTextIndex]

# Grab the favicon from an html doc
favicon = (doc) ->
  tag = doc('link').filter ->
    doc(this).attr('rel')?.toLowerCase() == 'shortcut icon'
  tag.attr('href')

# Determine the language of an html doc
lang = (doc) ->
  # Check the <html> tag
  l = doc("html")?.attr("lang")

  if !l
    # Otherwise look up for a content-language in meta
    tag = doc("meta[name=lang]") || doc("meta[http-equiv=content-language]")
    l = tag?.attr("content")

  if l
    # Just return the 2 letter ISO language code with no country
    value = l[0..1]
    if /^[A-Za-z]{2}$/.test(value)
      return value.toLowerCase()

  null

# Get the meta description of an html doc
description = (doc) ->
  tag = doc("meta[name=description]")
  tag?.attr("content")?.trim()

# Get the meta keywords of an html doc
keywords = (doc) ->
  tag = doc("meta[name=keywords]")
  tag?.attr("content")

# Get the canonical link of an html doc
canonicalLink = (doc) ->
  tag = doc("link[rel=canonical]")
  tag?.attr("href")

# Get any tags or keywords from an html doc
extractTags = (doc) ->
  elements = doc("a[rel='tag']")

  if elements.length == 0
    elements = doc("a[href*='/tag/'], a[href*='/tags/'], a[href*='/topic/'], a[href*='?keyword=']")
    if elements.length == 0
      return []

  tags = []
  elements.each () ->
    el = doc(this)
    tag = el.text()
    if tag && tag.length > 0
      tags.push(tag)

  _.uniq(tags)

# Walk the document's text nodes and find the most 'texty' node in the doc
calculateBestNode = (doc, lang) ->
  topNode = null
  nodesToCheck = doc("p, pre, td")

  startingBoost = 1.0
  cnt = 0
  i = 0
  parentNodes = []
  nodesWithText = []

  # Walk all the p, pre and td nodes
  nodesToCheck.each () ->
    node = doc(this)

    textNode = node.text()
    wordStats = stopwords(textNode, lang)
    highLinkDensity = isHighlinkDensity(doc, node)

    # If a node contains multiple common words and isn't just a bunch
    # of links, it's worth consideration of being 'texty'
    if wordStats.stopwordCount > 2 && !highLinkDensity
      nodesWithText.push(node)

  nodesNumber = nodesWithText.length
  negativeScoring = 0
  bottomNegativescoreNodes = nodesNumber * 0.25

  # Walk all the potentially 'texty' nodes
  _.each nodesWithText, (node) ->
    boostScore = 0.0

    # If this node has nearby nodes that contain
    # some good text, give the node some boost points
    if isBoostable(doc, node, lang) == true
      if cnt >= 0
        boostScore = (1.0 / startingBoost) * 50
        startingBoost += 1

    if nodesNumber > 15
      if (nodesNumber - i) <= bottomNegativescoreNodes
        booster = bottomNegativescoreNodes - (nodesNumber - i)
        boostScore = -1.0 * Math.pow(booster, 2)
        negscore = Math.abs(boostScore) + negativeScoring

        if negscore > 40
          boostScore = 5.0

    # Give the current node a score of how many common words
    # it contains plus any boost
    textNode = node.text()
    wordStats = stopwords(textNode, lang)
    upscore = Math.floor(wordStats.stopwordCount + boostScore)

    # Propigate the score upwards
    parentNode = node.parent()
    updateScore(parentNode, upscore)
    updateNodeCount(parentNode, 1)

    if parentNodes.indexOf(parentNode[0]) == -1
      parentNodes.push(parentNode[0])

    parentParentNode = parentNode.parent()

    if parentParentNode
      updateNodeCount(parentParentNode, 1)
      updateScore(parentParentNode, upscore / 2)

      if parentNodes.indexOf(parentParentNode[0]) == -1
        parentNodes.push(parentParentNode[0])

    cnt += 1
    i += 1

  topNodeScore = 0

  # Walk each parent and parent-parent and find the one that
  # contains the highest sum score of 'texty' child nodes.
  # That's probably out best node!
  _.each parentNodes, (e) ->
    score = getScore(doc(e))

    if score > topNodeScore
      topNode = e
      topNodeScore = score

    if topNode == null
      topNode = e

  doc(topNode)

# Given a text node, check all previous siblings.
# If the sibling node looks 'texty' and isn't too many
# nodes away, it's probably some yummy text
isBoostable = (doc, node, lang) ->
  stepsAway = 0
  minimumStopwordCount = 5
  maxStepsawayFromNode = 3

  nodes = node.prevAll()

  boostable = false

  nodes.each () ->
    currentNode = doc(this)
    currentNodeTag = currentNode[0].name

    if currentNodeTag == "p"
      # Make sure the node isn't more than 3 hops away
      if stepsAway >= maxStepsawayFromNode
        boostable = false
        return false

      paraText = currentNode.text()
      wordStats = stopwords(paraText, lang)

      # Check if the node contains more than 5 common words
      if wordStats.stopwordCount > minimumStopwordCount
        boostable = true
        return false

      stepsAway += 1

  boostable

addSiblings = (doc, topNode, lang) ->
  baselinescoreSiblingsPara = getSiblingsScore(doc, topNode, lang)
  sibs = topNode.prevAll()

  sibs.each () ->
    currentNode = doc(this)
    ps = getSiblingsContent(doc, lang, currentNode, baselinescoreSiblingsPara)
    _.each ps, (p) ->
      topNode.prepend("<p>#{p}</p>")
  return topNode

getSiblingsContent = (doc, lang, currentSibling, baselinescoreSiblingsPara) ->

  if currentSibling[0].name == 'p' && currentSibling.text().length > 0
    return [currentSibling]
  else
    potentialParagraphs = currentSibling.find("p")
    if potentialParagraphs == null
      return null
    else
      ps = []
      potentialParagraphs.each () ->
        firstParagraph = doc(this)
        txt = firstParagraph.text()

        if txt.length > 0
          wordStats = stopwords(txt, lang)
          paragraphScore = wordStats.stopwordCount
          siblingBaselineScore = 0.30
          highLinkDensity = isHighlinkDensity(doc, firstParagraph)
          score = baselinescoreSiblingsPara * siblingBaselineScore

          if score < paragraphScore && !highLinkDensity
            ps.push(txt)

      return ps

getSiblingsScore = (doc, topNode, lang) ->
  base = 100000
  paragraphsNumber = 0
  paragraphsScore = 0
  nodesToCheck = topNode.find("p")

  nodesToCheck.each () ->
    node = doc(this)
    textNode = node.text()
    wordStats = stopwords(textNode, lang)
    highLinkDensity = isHighlinkDensity(doc, node)

    if wordStats.stopwordCount > 2 && !highLinkDensity
      paragraphsNumber += 1
      paragraphsScore += wordStats.stopwordCount

  if paragraphsNumber > 0
    base = paragraphsScore / paragraphsNumber

  return base

# Keep track of a node's score with a gravityScore attribute
updateScore = (node, addToScore) ->
  currentScore = 0
  scoreString = node.attr('gravityScore')
  if scoreString
    currentScore = parseInt(scoreString)

  newScore = currentScore + addToScore
  node.attr("gravityScore", newScore)

# Keep track of # of 'texty' child nodes under this node with
# graveityNodes attribute
updateNodeCount = (node, addToCount) ->
  currentScore = 0
  countString = node.attr('gravityNodes')
  if countString
    currentScore = parseInt(countString)

  newScore = currentScore + addToCount
  node.attr("gravityNodes", newScore)

# Check the ratio of links to words in a node.
# If the ratio is high, this node is probably trash.
isHighlinkDensity = (doc, node) ->
  links = node.find('a')
  return false unless links.length > 0

  txt = node.text()
  words = txt.split(' ')
  wordsNumber = words.length

  sb = []
  links.each () ->
    sb.push(doc(this).text())

  linkText = sb.join('')
  linkWords = linkText.split(' ')
  numberOfLinkWords = linkWords.length
  numberOfLinks = links.length
  linkDivisor = numberOfLinkWords / wordsNumber
  score = linkDivisor * numberOfLinks

  score >= 1.0

# Return a node's gravity score (amount of texty-ness under it)
getScore = (node) ->
  grvScoreString = node.attr('gravityScore')
  if !grvScoreString
    return 0
  else
    parseInt(grvScoreString)


isTableAndNoParaExist = (doc, e) ->
  subParagraphs = e.find("p")

  subParagraphs.each () ->
    p = doc(this)
    txt = p.text()

    if txt.length < 25
      doc(p).remove()

  subParagraphs2 = e.find("p")
  if subParagraphs2.length == 0 && e[0].name != "td"
    return true
  else
    return false

isNodescoreThresholdMet = (doc, node, e) ->
  topNodeScore = getScore(node)
  currentNodeScore = getScore(e)
  thresholdScore = topNodeScore * 0.08

  if (currentNodeScore < thresholdScore) && e[0].name != 'td'
    return false
  else
    return true

# Remove any remaining trash nodes (clusters of nodes with little/no content)
postCleanup = (doc, targetNode, lang) ->
  node = addSiblings(doc, targetNode, lang)

  node.children().each () ->
    e = doc(this)
    eTag = e[0].name
    if eTag != 'p'
      if isHighlinkDensity(doc, e) || isTableAndNoParaExist(doc, e) || !isNodescoreThresholdMet(doc, node, e)
        doc(e).remove()
  return node
