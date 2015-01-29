{View}      = require 'atom-space-pen-views'
_           = require 'underscore-plus'
util        = require '../mavensmate-util'
pluralize   = require 'pluralize'
emitter     = require('../mavensmate-emitter').pubsub

class CommandParser
  
  obj:
    message: null
    indicator: 'warning'
    stackTrace: null
    result: null
    isException: false

  constructor: (@command, @params, @result) ->
    @obj.result = result

  parse: ->
    console.log('parsing!')
    console.log @result
    if @result.result? and not @result.error?
      @result.success = true
      @obj.message = @result.result
      @obj.indicator = if @result.success then 'success' else 'danger'
      @obj.stackTrace = @result.stack
      @obj.isException = @result.stack?
    else if @result.result? and @result.error
      @obj = @getErrorOutput()
    else
      @obj.message = 'Unable to parse the command\'s result. This really should not happen, so please generate a log and create a GitHub issue (please search before creating new issues!)'
      @obj.indicator = 'warning'
      @obj.stackTrace = @result.stack
      @obj.isException = @result.stack?

    return @obj

  getErrorOutput: ->
    output =
      message: @result.result
      indicator: 'danger'
      stackTrace: @result.stack
      isException: @result.stack?

class GetOrgWideTestCoverageParser extends CommandParser

  parse: ->
    @obj.indicator = 'info'
    @obj.message = "Total Apex Unit Test Coverage: #{@result.PercentCovered}%"
    return @obj

class DeleteParser extends CommandParser

  parse: ->
    if @result.result.success
      @obj.indicator = "success"
      if @params.payload.paths? and @params.payload.paths.length is 1
        @obj.message = 'Deleted ' + util.baseName(@params.payload.paths[0])
      else
        @obj.message = "Deleted selected metadata"
      return @obj
    else
      @getErrorOutput @params, @result

class UiParser extends CommandParser

  parse: ->
    if @result.success
      @obj.message = 'UI generated successfully'
      @obj.indicator = 'success'
      return @obj
    else
      return @getErrorOutput @params, @result

class CompileParser extends CommandParser

  parse: ->
    if @result.error?
      if @result.result? and _.isString(@result.result) and @result.error?
        @obj.message = @result.result+': '+@result.error
      else
        @obj.message = @result.error
      @obj.success = false
      @obj.indicator = 'danger'
      return @obj

    panelMessages = []
    compileResult = @result.result
    console.log 'result!'
    console.log compileResult

    @obj.success = compileResult.success
    @obj.indicator = if !compileResult.success then 'danger' else 'success'

    filesCompiled = {}
    errorsByFilePath = {}

    if @params.payload? and @params.payload.paths?
      for filePath in @params.payload.paths
        fileNameBase = util.baseName(filePath)
        fileNameWithoutExtension = util.withoutExtension(fileNameBase)
        compiledFile = {}
        compiledFile.filePath = filePath
        compiledFile.fileNameWithoutExtension = fileNameWithoutExtension
        compiledFile.fileNameBase = fileNameBase
        filesCompiled[fileNameWithoutExtension] = compiledFile
        atom.project.mavensMateErrors[filePath] = []

    for filePath, errors of atom.project.mavensMateErrors
      fileNameBase = util.baseName(filePath)
      fileNameWithoutExtension = util.withoutExtension(fileNameBase)

      if not filesCompiled[fileNameWithoutExtension]?
        compiledFile = {}
        compiledFile.filePath = filePath
        compiledFile.fileNameWithoutExtension = fileNameWithoutExtension
        compiledFile.fileNameBase = fileNameBase
        filesCompiled[fileNameWithoutExtension] = compiledFile

    if !compileResult.success or compileResult == 'false'
      panelMessages.push 'Compile Failed'
    else
      panelMessages.push 'Compile Completed Successfully'

    resultsArray = if @obj.success then compileResult.details.componentSuccesses else compileResult.details.componentFailures
    if not _.isArray(resultsArray)
      resultsArray = [resultsArray]

    for result in resultsArray
      console.log 'compile result -->'
      console.log result

      if result.State? # tooling api result
        if result.State is 'Error' and result.ErrorMsg?
          panelMessages.push result.ErrorMsg
        else if result.State is 'Failed' and result.CompilerErrors?
          if Object.prototype.toString.call result.CompilerErrors is '[object String]'
            result.CompilerErrors = JSON.parse result.CompilerErrors

          errors = result.CompilerErrors
          for error in errors
            if filesCompiled[error.name]?
              error.fileName = filesCompiled[error.name].fileNameBase
              error.filePath = filesCompiled[error.name].filePath
            else
              error.fileName = error.name
              error.filePath = error.name
            if error.line?
              panelMessages.push "#{error.fileName}: #{error.problem[0]} (Line: #{error.line[0]})"
              error.lineNumber = error.line[0]
            else
              panelMessages.push "#{error.fileName}: #{error.problem}"

            errorsByFilePath[error.filePath] ?= []
            errorsByFilePath[error.filePath].push(error)
        else if result.State is 'Failed' and result.DeployDetails?
          errors = result.DeployDetails.componentFailures
          console.log 'compile errors: '
          console.log errors
          for error in errors
            console.log error
            errorName = error.fileName || error.fullName || error.name
            if filesCompiled[errorName]?
              error.fileName = filesCompiled[errorName].fileNameBase
              error.filePath = filesCompiled[errorName].filePath
            else
              error.fileName = errorName
              error.filePath = errorName
            if error.lineNumber
              panelMessages.push "#{error.fileName}: #{error.problem} (Line: #{error.lineNumber})"
            else
              panelMessages.push "#{error.fileName}: #{error.problem}"

            errorsByFilePath[error.filePath] ?= []
            errorsByFilePath[error.filePath].push(error)
      else if result.componentType? and result.fullName? and result.fileName? # metadata API result
        console.log('metadata RESULT')
        console.log(result)
        if not result.success or result.success == 'false'
          errorName = result.fileName || result.fullName || result.name
          if filesCompiled[errorName]?
            result.fileName = filesCompiled[errorName].fileNameBase
            result.filePath = filesCompiled[errorName].filePath
          else
            result.fileName = errorName
            result.filePath = errorName
          
          # errorsByFilePath[result.fileName] ?= []
          # errorsByFilePath[result.fileName].push(result)
          panelMessages.push "#{result.fileName}: #{result.problem} (Line: #{result.lineNumber})"

          errorsByFilePath[result.filePath] ?= []
          errorsByFilePath[result.filePath].push(result)
      else if result.id? and result.errors? # lightning result
        if !result.success or result.success == 'false'
          panelMessages.push result.error

    console.log 'ok'
    console.log @command
    console.log compileResult.success
    
    # if the project compiled successfully, we can safely empty the error dictionary
    if @command == 'compile-project' and compileResult.success
      atom.project.mavensMateErrors = {}
    else
      console.log 'errorsByFilePath'
      console.log errorsByFilePath
      console.log 'atom.project.mavensMateErrors'
      console.log atom.project.mavensMateErrors
      for filePath, errors of errorsByFilePath
        fileNameBase = util.baseName(filePath)
        fileNameWithoutExtension = util.withoutExtension(fileNameBase)
        if atom.project.mavensMateErrors[fileNameWithoutExtension]?
          delete atom.project.mavensMateErrors[fileNameWithoutExtension]
        atom.project.mavensMateErrors[filePath] = errors
    
    console.log 'panel messages after compile parsing: '
    console.log panelMessages
    
    @obj.message = panelMessages.join('<br/>')
    if !@obj.message?
      throw new Error 'unable to parse compile result'
    
    return @obj

class CleanProjectParser extends CommandParser

  parse: ->
    atom.project.mavensMateErrors = {}
    super

class RefreshMetadataParser extends CommandParser

  parse: ->
    filesRefreshed = (util.baseName(filePath) for filePath in @params.payload.paths ? [])
    for refreshedFile in filesRefreshed
      atom.project.mavensMateErrors[refreshedFile] = []
    super

class RunTestsParser extends CommandParser

  class TestResultView extends View
    
    @content: (params) ->
      @div =>
        @span params.message
        @div outlet: 'results', class: 'mavensmate-test-result'
          
    addTestResults: (result) ->
      console.log 'adding result for: '
      console.log result
      html = ''
      
      passCounter = 0
      failedCounter = 0
      
      for test in result.results
        if test.Outcome == "Fail"
          failedCounter++
        else
          passCounter++

        
        clsName = 'Pass'
        if failedCounter > 0
          clsName = 'Fail'

      html += '<p class="class-name">'+result.ApexClass.Name
      html += ' | <span class="'+clsName+'">'+result.ExtendedStatus+' '+pluralize('test', result.results.length)+ ' passed</span>'
      html += '</p>'
      
      for test in result.results
        html += '<p class="method-name"><span class="result '+test.Outcome+'">['+test.Outcome+']</span> '+test.MethodName+'</p>'
        if test.Outcome == 'Fail'
          html += '<p class="stack">'
          html += test.Message
          html += '<br/>'
          html += test.StackTrace
          html += '</p>'
      
      console.log html

      @results.append html

  commandAliases: ['test_async']

  parse: ->
    passCounter = 0
    failedCounter = 0

    message = 'Results:\n'
      
    # console.log parserViews
    testResultView = new TestResultView(message:'> Results:')
    testKey = Object.keys(@result.result.testResults)[0]
    testResultsForThisClass = @result.result.testResults[testKey]
    testResultView.addTestResults(testResultsForThisClass)
    console.log testResultView
    # # console.log markdown
    # htmlMessage = converter.makeHtml(markdown)
    @obj.indicator = 'info'
    # @obj.message = message + htmlMessage
    @obj.message = testResultView

    # totalTests = passCounter + failedCounter
    # if failedCounter == 0
    #   @obj.message = "Run tests. #{passCounter} tests " + (if passCounter > 1 then "s " else " ") + "passed."
    #   @obj.indicator = 'success'
    # else
    #   @obj.indicator = 'danger'
    #   @obj.isException = true

    return @obj

class LoggingParser extends CommandParser

  parse: ->
    if @result.error?
      @obj.indicator = 'danger'
      @obj.isException = true
      @obj.stackTrace = @result.stack
    else
      @obj.indicator = 'info'

    @obj.message = @result.result
    return @obj

class OpenMetadataParser extends CommandParser

  parse: ->
    self = @
    setTimeout(->
      util.openUrlInAtom(self.result)
    , 100)
    super
      
parsers = {
  CommandParser: CommandParser,
  DeleteParser: DeleteParser,
  UiParser: UiParser,
  CompileMetadataParser: CompileParser,
  CompileProjectParser: CompileParser,
  RunTestsParser: RunTestsParser,
  TestAsyncParser: RunTestsParser,
  StartLoggingParser: LoggingParser,
  StopLoggingParser: LoggingParser,
  GetOrgWideTestCoverageParser: GetOrgWideTestCoverageParser,
  RefreshMetadataParser: RefreshMetadataParser,
  CleanProjectParser: CleanProjectParser,
  OpenMetadataParser: OpenMetadataParser
}

getCommandParser = (command, params) ->
  
  if params.args? and params.args.ui
    return UiParser
  else
    parserClassName = _.camelize(command)
    parserClassName = _.capitalize(parserClassName)
    parserClassName += 'Parser'
    console.log 'COMMAND RESULT PARSER --> '+parserClassName
    if parserClassName not of parsers
      return CommandParser
    else
      return parsers[parserClassName]

module.exports =
  
  parse: (command, params, result) ->
    Parser = getCommandParser(command, params)
    console.log 'parser is: '
    console.log Parser
    parser = new Parser(command, params, result)
    return parser.parse()