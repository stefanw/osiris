$ ->
  datasetUrl = "http://openspending.org/datasets.json"

  trim = (str) ->
    return str.replace(/^\s\s*/, '').replace(/\s\s*$/, '')

  class OpenSpendingAPI
    constructor: (@apiUrl) ->

    get: (url, options) ->
      url = url + '?' + $.param(options)
      d = $.Deferred()
      $.getJSON url, (data) ->
        d.resolve data
      d.promise()

    aggregate: (dataset, options) ->
      options = $.extend({}, options)
      options.dataset = dataset
      options.drilldown = options.drilldown or []
      options.drilldown = options.drilldown.join('|')

      options.cut = options.cut or {}
      options.cut = [k + ':' + v for k, v of options.cut]
      options.cut = options.cut.join('|')

      @get(@apiUrl + 'aggregate', options)

    search: (dataset, options) ->
      options.dataset = dataset
      options.filter = options.filter or {}
      options.filter = [k + ':' + v for k, v of options.filter]
      options.filter = options.filter.join('|')
      @get(@apiUrl + 'search', options)

  api = new OpenSpendingAPI("http://openspending.org/api/2/")

  modelCache = {}
  timeCache = {}
  getModel = (dataset, options) ->
    url = "http://openspending.org/" + dataset + "/model.json"
    d = $.Deferred()
    if modelCache[dataset]
      return modelCache[dataset]
    else
      $.getJSON url, (data) ->
        modelCache[dataset] = data
        d.resolve modelCache[dataset]

    d.promise()

  getTime = (dataset, options) ->
    url = "http://openspending.org/" + dataset + "/time.distinct.json"
    d = $.Deferred()
    if timeCache[dataset]
      return timeCache[dataset]
    else
      $.getJSON url, (data) ->
        times = {}
        i = 0

        while i < data.results.length
          times[data.results[i].year] = true
          i += 1
        timeCache[dataset] = times
        d.resolve timeCache[dataset]

    d.promise()

  getCurrenySpeak = (currency) ->
    trans =
      USD: "US Dollar"
      AUD: "Australian Dollar"
      EUR: "Euro"
      GBP: "Pound Sterling"
    trans[currency] || currency

  findInMapping = (current, origname) ->
    name = trim(origname.toLowerCase())
    transforms = [
      (name)->
        name = trim(origname.toLowerCase())
      ,
      (name)->
        name = name.replace(/ies$/, 'y')
        name = name.replace(/s$/, '')
      ,
      (name)->
        name = name.split(' ')[0]
      (name)->
        name = name.replace(/ies$/, 'y')
        name = name.replace(/s$/, '')
    ]
    for trans in transforms
      name = trans(name)
      for key, value of current.model.mapping
        return key if name is key.toLowerCase()
        return key if value.label and name is value.label.toLowerCase()
        return key if name.indexOf(key.toLowerCase()) is 0
        return key if value.label and name.indexOf(value.label.toLowerCase()) is 0
      return "to"  if name.indexOf('recipient') is 0
      return "from" if name.indexOf('spender') is 0
    throw new Error(origname + ' is not a dimension')


  class Trait
    constructor: (@current) ->
    match: (text) ->
      @args = text.match(@regex)

  class YearFilter extends Trait
    regex: /(?:in the year of|of|in) (\d{4})/

    run: (options) ->
      if not @args?
        return options
      if not @current.times[@args[1]]?
        throw new Error('Year ' + @args[1] + 'is not available')
      options.cut = options.cut or {}
      options.cut['time.year'] = @args[1]
      return options

    buildReply: () ->
      if not @args?
        return null
      "in #{@args[1]}"

  class OrderTrait extends Trait
    regex: /by ([\w ]+)/

    run: (options) ->
      if not @args?
        @args = ['', 'amount']
      key = findInMapping(@current, @args[1])
      options.order = key
      return options

    buildReply: () ->
      if not @args?
        return null
      "by #{@args[1]}"


  class Question
    constructor: (@current) ->

    match: (@text) ->
      @traits = []
      for trait in @traitClasses
        t = new trait(@current)
        t.match(text)
        @traits.push(t)
        if t.args?
          text = text.replace(t.args[0], '')

      @args = text.match(@regex)
      return @args?

    runTraits: () ->
      for trait in @traits
        @options = trait.run(@options)

    interpret: () ->
      @options = {
        cut: {}
      }
      @runTraits()
      @prepare()

    getInterpretation: () ->
      @interpret()
      return @repr + ' - ' + JSON.stringify(@options)

    prepare: () ->

    think: () ->
      @interpret()
      @run()

    getTraitReply: (data) ->
      reply = (trait.buildReply(data) for trait in @traits)
      reply = reply.join(' ')
      if reply then ' ' + reply else ''

    buildReply: (data) ->
      JSON.stringify(data) + @getTraitReply(data)

  class AggregateQuestion extends Question
    repr: "aggregate"
    run: () ->
      d = $.Deferred()
      $.when(api.aggregate(@current.dataset, @options)).then (data) =>
        d.resolve(
          message: @buildReply(data)
          data: data
          html: null
        )

      d.promise()

  class Who extends Question
    traitClasses: [YearFilter, OrderTrait]

    getDimension: () ->
      @args[2]

    prepare: () ->
      @options.pagesize = 1
      key = findInMapping(@current, @getDimension())
      @drillDownLabel = @current.model.mapping[key].label or @args[2]
      @options.drilldown = [key]
      super

    run: () ->
      d = $.Deferred()
      $.when(api.aggregate(@current.dataset, @options)).then (data) =>
        d.resolve(
          message: @buildReply(data)
          data: data
          html: null
        )

      d.promise()

    buildReply: (data) ->
      recipient = data.drilldown[0][@options.drilldown[0]]
      recipient = recipient.label or recipient.name
      amount = OpenSpending.Utils.formatAmountWithCommas(data.drilldown[0].amount)
      "#{recipient} is the #{@canonical} #{@drillDownLabel}#{@getTraitReply(data)}
 with #{amount} #{getCurrenySpeak(data.summary.currency.amount)}"

  class WhoMax extends Who
    regex: /(?:who|what's|(?:(?:what|which) (?:is|was))).* (most|top|biggest|largest) ([\w ]+)/i
    canonical: "biggest"
    prepare: () ->
      @options.order = @options.order + ":desc"
      super

  class WhoMaxWhich extends WhoMax
    regex: /(?:which|what) ([\w ]+) .*(most|top|biggest|largest)/i
    getDimension: () ->
      @args[1]

  class WhoMin extends Who
    regex: /(?:who|what's|(?:(?:what|which) (?:is|was))).* (smallest) ([\w ]+)/i
    canonical: "smallest"
    prepare: () ->
      @options.order = @options.order + ":asc"
      super

  class WhoMinWhich extends WhoMin
    regex: /(?:which|what) ([\w ]+) .*(smallest)/i
    getDimension: () ->
      @args[1]

  class TotalAmount extends AggregateQuestion
    traitClasses: [YearFilter]
    regex: /(?:what(?:'s| is| was)) .*(?:total|received|spent)/i

    buildReply: (data) ->
      amount = data.summary.amount
      currency = getCurrenySpeak(data.summary.currency.amount)
      trait = @getTraitReply(data)
      "The total amount#{trait} was #{amount} #{currency}"

  class SearchQuestion extends Question
    repr: 'search'

    run: () ->
      d = $.Deferred()
      $.when(api.search(@current.dataset, @options)).then (data) =>
        d.resolve(
          message: @buildReply(data)
          data: data
          html: null
        )
      d.promise()

  class CountQuestion extends SearchQuestion
    traitClasses: [YearFilter]
    regex: /(?:How many) ([\w ]+)/i

    prepare: () ->
      @options.drilldown

    prepare: () ->
      @options.pagesize = 1
      key = findInMapping(@current, @args[1])
      @drillDownLabel = @current.model.mapping[key].label or @args[1]
      @options.facet_field = key
      @options.filter = @options.cut
      super

    buildReply: (data) ->
      count = data.stats.results_count_query
      trait = @getTraitReply(data)
      "There were #{count} #{@drillDownLabel}s#{trait}."

  questions = [CountQuestion, TotalAmount, WhoMax,
               WhoMaxWhich, WhoMin, WhoMinWhich]

  findQuestion = (current, text) ->
    for question in questions
      q = new question(current)
      if q.match(text)
        return q

  current =
    model: null
    times: null
    dataset: null

  answerQuestion = (text, opts = {}) ->
    opts.speak = true
    question = findQuestion(current, text)
    if not question
      window.speak "Sorry, I don't understand."  if opts.speak
      $("#info").text('Could not interpret')
      return
    try
      interpretation = question.getInterpretation()
    catch error
      window.speak error.message if opts.speak
      $("#info").append error.message
      throw error
      return
    $("#info").append interpretation
    $('#thinking').show()
    window.speak "Let me think about that."  if opts.speak

    d = question.think()
    $.when(d).then (answer) ->
      window.speak answer.message  if opts.speak
      $('#answer').text(answer.message)
      $('#thinking').hide()
      $("#info").append JSON.stringify(answer)


  $.getJSON datasetUrl, (data) ->
    $('#dataset-loading').hide();
    $('#dataset-label').fadeIn();
    $("#datasets").html ""
    $("#datasets").append "<option></option>"
    $.each data.datasets, (i) ->
      dataset = data.datasets[i]
      $("#datasets").append "<option value=\"" + dataset.name + "\">" + dataset.label + "</option>"
    $("#datasets").chosen()
    $("#datasets").change (e) ->
      $("#dataset-label").hide()
      $("#speech-label").fadeIn()
      window.setTimeout (->
        $("#question").focus()
        $("#dataset-container").hide()
        $("#datasets-form").append $("#dataset-container")
        $("#dataset-container").fadeIn()
        $("#dataset-label").remove()
      ), 500
      dataset = $(this).val()
      return  unless dataset
      current.dataset = dataset
      getModel(dataset).then (data) ->
        current.model = data
        dim = $("#dimensions").html("")
        for key of data.mapping
          dim.append $("<li>").text(data.mapping[key].label)

      getTime(dataset).then (data) ->
        current.times = data
        years = $('#years').html('')
        for key, value of data
          years.append $("<li>").text(key)



  $("#question").on "webkitspeechchange", ->
    answerQuestion $(this).val(),
      speak: true


  $("#question").keydown (e) ->
    if e.keyCode == 13
      e.preventDefault()
      answerQuestion $("#question").val()

  findLeastLevenshtein = (haystack, needle) ->
