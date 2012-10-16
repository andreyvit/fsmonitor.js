{ RelPathList, RelPathSpec } = require 'pathspec'

fsmonitor = require './index'
{ spawn } = require 'child_process'


USAGE = """
Usage: fsmonitor [-d <folder>] [-p] [-s] [-q] [<mask>]... [<command> <arg>...]

Options:
  -d <folder>        Specify the folder to monitor (defaults to the current folder)
  -p                 Print changes to console (default if no command specified)
  -s                 Run the provided command once on start up
  -q                 Quiet mode (don't print the initial banner)

Masks:
  +<mask>            Include only the files matching the given mask
  !<mask>            Exclude files matching the given mask

  If no inclusion masks are provided, all files not explicitly excluded will be included.

General options:
  --help             Display this message
  --version          Display fsmonitor version number
"""


escapeShellArgForDisplay = (arg) ->
  if arg.match /[ ]/
    if arg.match /[']/
      '"' + arg.replace(/[\\]/g, '\\\\').replace(/["]/g, '\\"') + '"'
    else
      "'#{arg}'"
  else
    arg

displayStringForShellArgs = (args) ->
  (escapeShellArgForDisplay(arg) for arg in args).join(' ')


class FSMonitorTool
  constructor: ->
    @list = new RelPathList()
    @included = []
    @excluded = []
    @folder = process.cwd()
    @command = []
    @print = no
    @quiet = no
    @prerun = no

    @_latestChangeForExternalCommand = null
    @_externalCommandRunning = no


  parseCommandLine: (argv) ->
    requiredValue = (arg) ->
      if argv.length is 0
        process.stderr.write " *** Missing required value for #{arg}.\n"
        process.exit(13)
      return argv.shift()

    while (arg = argv.shift())?
      break if arg is '--'

      if arg.match /^--/
        switch arg
          when '--help'
            process.stdout.write USAGE.trim() + "\n"
            process.exit(0)
          when '--version'
            process.stdout.write "#{fsmonitor.version}\n"
            process.exit(0)
          else
            process.stderr.write " *** Unknown option: #{arg}.\n"
            process.exit(13)
      else if arg.match /^-./
        switch arg
          when '-d'
            @folder = requiredValue()
          when '-p'
            @print = yes
          when '-s'
            @prerun = yes
          when '-q'
            @quiet = yes
          else
            process.stderr.write " *** Unknown option: #{arg}.\n"
            process.exit(13)
      else
        if arg.match /^!/
          @excluded.push arg.slice(1)
        else if arg.match /^[+]/
          @included.push arg.slice(1)
        else
          argv.unshift(arg)
          break

    @command = argv
    @print = yes  if @command.length is 0

    if @included.length > 0
      for mask in @included
        @list.include RelPathSpec.parseGitStyleSpec(mask)
    else
      @list.include RelPathSpec.parse('**')

    for mask in @excluded
      @list.exclude RelPathSpec.parseGitStyleSpec(mask)


  printOptions: ->
    if @command.length > 0
      action = displayStringForShellArgs(@command)
    else
      action = '<print to console>'

    folderStr = @folder.replace(process.env.HOME, '~')

    process.stderr.write "\n"
    process.stderr.write "Monitoring:  #{folderStr}\n"
    process.stderr.write "    filter:  #{@list}\n"
    process.stderr.write "    action:  #{action}\n"
    process.stderr.write "\n"


  startMonitoring: ->
    fsmonitor.watch(@folder, @list, @handleChange.bind(@))


  handleChange: (change) ->
    @printChange(change)              if @print
    @executeCommandForChange(change)  if @command.length > 0


  printChange: (change) ->
    str = change.toString()
    prefix = "#{Date.now()} "
    if str
      process.stderr.write "\n" + str.trim().split("\n").map((x) -> "#{prefix}#{x}\n").join('')
    else
      process.stderr.write "\n#{prefix} <empty change>\n"


  executeCommandForChange: (change) ->
    @_latestChangeForExternalCommand = change
    @_scheduleExternalCommandExecution()

  _scheduleExternalCommandExecution: ->
    if @_latestChangeForExternalCommand and not @_externalCommandRunning
      process.nextTick =>
        change = @_latestChangeForExternalCommand
        @_latestChangeForExternalCommand = null

        @_externalCommandRunning = yes

        process.stderr.write "#{displayStringForShellArgs(@command)}\n"
        child = spawn(@command[0], @command.slice(1), stdio: 'inherit')

        child.on 'exit', =>
          @_externalCommandRunning = no
          @_scheduleExternalCommandExecution()  # execute again if any more changes came in


exports.run = (argv) ->
  app = new FSMonitorTool()
  app.parseCommandLine(argv)
  app.startMonitoring()
  app.executeCommandForChange({}) if app.prerun
  app.printOptions() unless app.quiet
