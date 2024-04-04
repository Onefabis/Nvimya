"""
"
" Coypright 2009, 2013-2014, 2018, 2021 Stefan Goebel - <vimya /at/ subtype /dot/ de>,
"                                       Talha Ahmed   - <talha /dot/ ahmed /at/ gmail /dot/ com>.
"
" This program is free software: you can redistribute it and/or modify it under the terms of the
" GNU General Public License as published by the Free Software Foundation, either version 3 of the
" License, or (at your option) any later version.
"
" This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
" even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
" General Public License for more details.
"
" You should have received a copy of the GNU General Public License along with this program. If
" not, see <http://www.gnu.org/licenses/>.
"
"""

"""
"
" Vimya 0.6 - Execute buffer contents as MEL or Python scripts in Autodesk Maya.
"
" Help is available in doc/vimya.txt or from within Vim:
"
"   :help vimya
"
" Help for all the Python functions can also be accessed in Vim the Python way:
"
"   :py help (<function>)
"
"""

let g:vimyaLoaded = '0.6'

"""
" Configuration variables:
"""

function VimyaSetConfig (name, default)
    if ! exists ('g:vimya' . a:name)
        let {'g:vimya' . a:name} = a:default
    endif
endfunction

call VimyaSetConfig ( 'DefaultFiletype',  'python'    )
call VimyaSetConfig ( 'ForceRefresh',     0           )
call VimyaSetConfig ( 'Host',             '127.0.0.1' )
call VimyaSetConfig ( 'Port',             12345       )
call VimyaSetConfig ( 'RefreshWait',      2.0         )
call VimyaSetConfig ( 'ShowLog',          1           )
call VimyaSetConfig ( 'Socket',           ''          )
call VimyaSetConfig ( 'SplitBelow',       &splitbelow )
call VimyaSetConfig ( 'TailCommand',      'TabTail'   )
call VimyaSetConfig ( 'TempDir',          ''          )
call VimyaSetConfig ( 'Timeout',          5.0         )

"""
" Mappings:
"""

if ! hasmapto (':py sendBufferToMaya') && ! hasmapto (':py vimyaRun')
    nnoremap <leader>sm :py vimyaRun ()<cr>
    vnoremap <leader>sm :py vimyaRun ()<cr>
    nnoremap <leader>sb :py vimyaRun (forceBuffer = True)<cr>
    vnoremap <leader>sb :py vimyaRun (forceBuffer = True)<cr>
endif

"""
" Commands:
"""

command -nargs=0 VimyaRun     :py vimyaRun    ()
command -nargs=0 VimyaBuffer  :py vimyaRun    (forceBuffer = True    )
command -nargs=1 VimyaCommand :py vimyaRun    (userCmd     = <q-args>)
command -nargs=1 VimyaSend    :py vimyaSend   ([<q-args>]            )
command -nargs=? VimyaWhatIs  :py vimyaWhatIs (<q-args>              )

"""
" Main stuff (most of it is Python):
"""

let g:vimyaTailAvailable = 0
if exists (':Tail')
    let g:vimyaTailAvailable = 1
endif

autocmd VimLeavePre * py __vimyaRemoveTempFiles ()

python << EOP

import os
import platform
import socket
import tempfile
import time
import neovim
import re

# Global variables:
#
#   __vimyaLogPath   - If not empty, path of the log file currently used by Maya.
#   __vimyaTempFiles - Contains all the temporary files created (log files, MEL/Python files).

__vimyaLogPath   = ''
__vimyaTempFiles = []

def __vimyaRemoveTempFiles ():

    """Remove all temporary files.

    __vimyaRemoveTempFiles () : None

    This function will be called automatically when leaving Vim. It will try to delete all the
    temporary files created during the session. There is no error handling, if deleting a file
    fails, the file will be left on disk.

    If a log file is set this function will try to close it first, see __vimyaStopLogging().

    This function does not return anything.
    """

    global __vimyaLogPath, __vimyaTempFiles

    if __vimyaLogPath != '':
        __vimyaStopLogging ()

    for tempFile in __vimyaTempFiles:
        if os.path.isfile (tempFile):
            try:
                os.unlink (tempFile)
            except:
                pass

def __vimyaStopLogging ():

    """Tell Maya to stop logging and close all open log files.

    __vimyaStopLogging () : bool

    If a log file is currently set, this function will send the `cmdFileOutput -closeAll` command
    to Maya, causing all (!) open log files to be closed. The __vimyaLogPath variable will be set
    to an empty string if the log file could be closed successfully, its original value will be
    added to the __vimyaTempFiles list for clean up on exit.

    If the connection fails, an error message will be shown and the return value will be False,
    else this function returns True. If no log file has been set, this function does nothing and
    returns True.
    """

    global __vimyaLogPath, __vimyaTempFiles

    if __vimyaLogPath == '':
        return True

    if vimyaSend (['cmdFileOutput -ca;']) == 1:
        __vimyaTempFiles.append (__vimyaLogPath)
        __vimyaLogPath = ''
        return True
    else:
        return __vimyaError ('Could not close the log file.')

def __vimyaError (message):

    """Print an error message.

    __vimyaError (message) : False

    This function will print the error message in Vim's message area, using the appropriate
    error highlighting.

    It will always return False.
    """

    vim.command ('echohl ErrorMsg | echo "%s" | echohl None' % __vimyaEscape (message, '\\"'))

    return False

def __vimyaEscape (string, characters):

    """Escape specified characters in a string with backslash.

    __vimyaEscape (string, characters) : str

    Works like Vim's escape() function. Every occurrence of one of the characters in the characters
    parameter inside the string will be replaced by '\' + character. The backslash itself has to be
    included as the first character in the characters parameter if it also should be escaped!

    Returns the resulting string.
    """

    for character in characters:
        string = string.replace (character, '\\%s' % character)

    return string

def __vimyaFilenameEscape (filename):

    """Apply Vim's fnameescape() function to a string.

    __vimyaFilenameEscape (string) : str

    This function may be used to apply Vim's fnameescape() function to the supplied parameter.

    Returns the escaped string.
    """

    return vim.eval ('fnameescape ("%s")' % __vimyaEscape (filename, '\\"'))

def __vimyaFixPath (filename):

    """Replace all backslashes in the file name with slashes on Windows platforms.

    __vimyaFixPath (filename) : str

    Replaces all backslashes in the file name with slashes on Windows platforms.

    Returns the resulting string.
    """

    if platform.system () == 'Windows':
        return filename.replace ('\\', '/')
    else:
        return filename

def __vimyaFindBuffer(path):

    """Find the buffer and tab that contains the given path.

    __vimyaFindBuffer (string) : (int, int)

    This function will return the number of the tab page and the buffer number in which the
    specified file is opened. Note: Searching will stop on first match!

    Returns a tuple: (tabNumber, bufferNumber). If the path is empty or not opened in any buffer,
    this function returns the tuple (0, 0) or (0, -1), respectively. If there is a buffer for log
    file, but it is not opened in any window (and thus in no tab), the return value will be
    (0, bufferNumber).
    """

    if path != '':
        bufferIndex  = int (vim.eval ('bufnr     ("%s")' % __vimyaEscape (path, '\\"')))
        bufferExists = int (vim.eval ('bufexists ( %d )' % int           (bufferIndex          )))
        if bufferExists:
            tabNum = int (vim.eval ('tabpagenr ("$")'))
            for tabIndex in range (1, tabNum + 1):
                tabBuffers = vim.eval ('tabpagebuflist (%d)' % tabIndex)
                if str (bufferIndex) in tabBuffers:
                    return (tabIndex, bufferIndex)
        return (0, bufferIndex)

    return (0, 0)

def __vimyaFindLog ():

    """Find the buffer and tab that contains the Maya log.

    __vimyaFindLog () : (int, int)

    If a Maya log file is currently set, this function will return the number of the tab page and
    the buffer number in which this log file is opened. Note: Searching will stop on first match!
    There is no convenient way to check if a window is a preview window without switching tabs, so
    this is not checked, the buffer found may be a regular window!

    Returns a tuple: (tabNumber, bufferNumber). If the log file is not set or not opened in any
    buffer, this function returns the tuple (0, 0) or (0, -1), respectively. If there is a buffer
    for the log file, but it is not opened in any window (and thus in no tab), the return value
    will be (0, bufferNumber).
    """

    global __vimyaLogPath
    return __vimyaFindBuffer(__vimyaLogPath)

def __vimyaGetLastLine(path, force_read=False):

    """Return the last line of the specified file.

    __vimyaGetLastLine (string, force_read = False) : str

    If the specified file is currently open in any buffer, the last line will be read from the
    buffer, unless force_read is set to True, in which case it is read from the filesystem
    regardless. If no buffer contains the file, it is read from the filesystem.
    """

    bufferIndex  = int (vim.eval ('bufnr     ("%s")' % __vimyaEscape (path, '\\"')))
    last_line = ''


    if force_read or bufferIndex == -1:
        # reading last line
        if os.path.isfile(path):
            size = os.path.getsize(path)
            with open(path, "rb") as _file:
                _file.seek(size, os.SEEK_SET)
                next_byte = _file.read(1)
                while next_byte != b"\n":
                    try:
                        _file.seek(-2, os.SEEK_CUR)
                    except IOError:
                        _file.seek(0, os.SEEK_SET)
                        break
                    next_byte = _file.read(1)
                last_line = _file.readline()

    else:
        last_line = vim.buffers[bufferIndex][-1]

    return last_line

def vimyaWhatIs(keyword=None):

    """Open (or switch to) a buffer containing the procedure specified by the keyword.

    vimyaWhatIs () : None

    This function will take the given argument, or, in its absence, the current word under the
    cursor, and pass it to Maya's `whatIs` procedure. It will open the path provided in the
    response (as read from the log file) in a new buffer, or switch to the respective window if
    there already is a buffer for the file.

    If any information is provided by the `whatIs` command it is `echom`ed.
    """

    __vimyaError(keyword)

    if not keyword:
        keyword = vim.eval('expand("<cword>")')
        keyWORD = vim.eval('expand("<cWORD>")')
        if '$'+keyword in keyWORD:
            keyword = '$' + keyword

    if not keyword or not re.match("\\$?[A-Za-z_](0-9A-Za-z_)*", keyword):
        __vimyaError("No valid keyword found");
        return

    # output whatIs info with tag to avoid confusion with any previous lines
    cmds = ['string $vimya_kw="%s";' % keyword,
            'string $vimya_res=`whatIs $vimya_kw`;',
            'print `format -s $vimya_kw -s $vimya_res "\\n^1s:^2s"`;']

    ft = vim.eval('&ft')
    vim.command('setl ft=mel')
    success = vimyaRun(userCmd=''.join(cmds))
    vim.command('setl ft=%s' % ft)

    response = __vimyaGetLastLine(
            __vimyaLogPath, not success or bool(vim.eval('g:vimyaForceRefresh')))

    info = ''
    info_pattern = '%s:(.*)' % keyword
    match = re.match(info_pattern, response)
    if match:
        info = match.group(1)

    mel_path = ''
    found_pattern = '%s:Mel procedure found in: (.*)' % keyword
    match = re.match(found_pattern, response)
    if match:
        mel_path = match.group(1)

    if info:
        vim.command('echom "%s:%s"' % (keyword, info.replace('"', '\\"' )))

    if mel_path:
        tabIndex, bufferIndex = __vimyaFindBuffer(mel_path)

        if not tabIndex:
            if bufferIndex < 1:
                vim.command ('e %s' % mel_path)
            else:
                vim.command ('b %d' % bufferIndex)
        else:
            vim.command ('tabnext %d' % tabIndex)
            winIndex = int (vim.eval ('bufwinnr (%d)' % bufferIndex))
            vim.command('wincmd t')
            vim.command('%dwincmd w' % winIndex)

        vim.eval('search("\\\\Cproc.*%s\\\\s*\\\\((\\\\|$\\\\)", "w")' % keyword)

        vim.command('normal! zz')

def vimyaRefreshLog ():

    """Update the log file in the preview window.

    vimyaRefreshLog () : bool

    This function will update the log file if it is currently opened in a preview window. If the
    window of the log file is not located in the current tab, it will switch to the window's tab.
    If the log file's window is a regular window, no attempt to refresh it will be made (the tab
    will be switched, though). Does nothing if no log file is currently set.

    If no log file is set, returns True. Same if a log file is set and opened in a preview window
    (or a regular window). If a log file is set, but not opened in any window, returns False (and
    prints an error message).
    """

    global __vimyaLogPath

    if __vimyaLogPath != '':

        (tabIndex, bufferIndex) = __vimyaFindLog ()

        if not tabIndex:
            return __vimyaError ('No log file window found.')
        else:
            vim.command ('tabnext %d' % tabIndex)
            winIndex = int (vim.eval ('bufwinnr (%d)' % bufferIndex))
            if winIndex > 0 and int (vim.eval ('getwinvar (%d, "&previewwindow")' % winIndex)):
                vim.command ('call tail#Refresh ()')

    return True

def vimyaOpenLog ():

    """Open the log file using the Tail Bundle plugin.

    vimyaOpenLog () : bool

    This function will open the currently used log file using the configured Tail Bundle command,
    unless this is disabled. The options g:vimyaShowLog, g:vimyaTailCommand and g:vimyaSplitBelow
    may be used to change the behaviour. If no log file is set, or the file is already opened in a
    window, this function does nothing. If g:vimyaTailCommand is not 'TabTail', any preview window
    currently opened will be closed.

    Returns False in case of an error, True in all other cases.
    """

    global __vimyaLogPath

    (tabIndex, bufferIndex) = __vimyaFindLog ()

    if __vimyaLogPath != '' and tabIndex == 0:

        splitBelowGlobal = int (vim.eval ('&splitbelow'       ))
        splitBelowVimya  = int (vim.eval ('g:vimyaSplitBelow' ))
        tailCommand      =      vim.eval ('g:vimyaTailCommand')

        if tailCommand not in ('Tail', 'STail', 'TabTail'):
            return __vimyaError ('Invalid value for g:vimyaTailCommand.')

        success = False

        try:
            if tailCommand != 'TabTail':
                vim.command ('pclose')
            if splitBelowVimya:
                vim.command ('set splitbelow')
            else:
                vim.command ('set nosplitbelow')
            vim.command ('%s %s' % (tailCommand, __vimyaFilenameEscape (__vimyaLogPath)))
            if tailCommand != 'TabTail':
                vim.command ('wincmd p')
            success = True
        finally:
            if splitBelowGlobal:
                vim.command ('set splitbelow')
            else:
                vim.command ('set nosplitbelow')

        return success

    return True

def vimyaResetLog ():

    """(Re)set Maya's log file.

    vimyaResetLog () : bool

    This function will create a temporary file and instruct Maya to use it as its log file. If a
    log file is already set, the command to close all (!) log files will be sent to Maya first,
    then the new file is set. The log file will be opened in Vim if enabled, see vimyaOpenLog()
    for details. If g:vimyaShowLog is not enabled (or the Tail Bundle plugin is not available), no
    new log file will be created (if a log file should be set, it will still be closed, though).

    Returns True on success, False in case of failure.
    """

    global __vimyaLogPath

    if __vimyaLogPath != '':
        if not __vimyaStopLogging ():
            return False

    tailAvailable = int (vim.eval ('g:vimyaTailAvailable'))
    showLog       = int (vim.eval ('g:vimyaShowLog'      ))

    if tailAvailable and showLog:

        tempDir = vim.eval ('g:vimyaTempDir')
        if tempDir != '':
            tempfile.tempdir = tempDir
        else:
            tempfile.tempdir = None

        (logHandle, logPath) = tempfile.mkstemp (suffix = '.log', prefix = 'vimya.', text = 1)
        __vimyaLogPath = vim.eval ('expand ("%s")' % __vimyaEscape (logPath, '\\"'))

        escapedLogPath = __vimyaEscape (__vimyaFixPath (__vimyaLogPath), '\\"')
        if vimyaSend (['cmdFileOutput -o "%s";' % escapedLogPath]) != 1:
            return False

        return vimyaOpenLog ()

    return True

def vimyaSend (commands):

    """Send commands to Maya's command port.

    vimyaSend (commands) : int

    This function will open a connection to Maya's command port (as configured), and send the
    commands - which must be a list of one or more strings - to Maya. A newline will be appended
    to every command automatically. Commands will be sent in the order they appear in the list.

    Socket exceptions will be caught and an appropriate error message will be displayed. After an
    exception, no attempt will be made to send any more commands from the list.

    Returns the number of commands successfully sent to Maya.
    """

    socketPath =      vim.eval ('g:vimyaSocket' )
    timeout    =      vim.eval ('g:vimyaTimeout')
    host       =      vim.eval ('g:vimyaHost'   )
    port       = int (vim.eval ('g:vimyaPort'   ))

    try:
        if socketPath != '':
            connection = socket.socket (socket.AF_UNIX, socket.SOCK_STREAM)
        else:
            connection = socket.socket (socket.AF_INET, socket.SOCK_STREAM)
        if timeout == '':
            connection.settimeout (None)
        else:
            connection.settimeout (float (timeout))
    except socket.error as e:
        __vimyaError ('Could not initialize the socket: %s' % str (e))
        return 0

    try:
        if socketPath != '':
            connection.connect (socketPath)
        else:
            connection.connect ((host, port))
    except socket.error as e:
        __vimyaError ('Could not connect to command port: %s' % str (e))
        return 0

    sent = 0

    try:
        try:
            for command in commands:
                connection.send ((command+'\n').encode())
                sent = sent + 1
        except socket.error as e:
            __vimyaError ('Sending a command failed: %s' % str (e))
    finally:
        connection.shutdown (socket.SHUT_WR)
        connection.close ()

    return sent

def vimyaRun (forceBuffer = False, userCmd = None):

    """Sent (partial) buffer contents or a single command to Maya's command port.

    vimyaRun (forcedBuffer = False, userCmd = None) : bool

    If userCmd is not specified, saves the current buffer to a temporary file and instructs Maya to
    source this file. In visual mode only the selected lines are used (for partially selected lines
    the complete line will be included). In visual mode, forceBuffer may be set to True to force
    execution of the complete buffer.

    If userCmd is specified, this command will be written to the file executed by Maya, and the
    buffer content will be ignored.

    In both cases, the current buffer's file type determines how the file is executed by Maya,
    either as MEL or Python script. The file type must be either 'mel' or 'python', or not set at
    all, in which case the 'g:vimyaDefaultFiletype' will be used.

    If Maya's log is not yet set, it will be set and opened (if configured), depending on the
    'g:vimyaShowLog' setting. See vimyaResetLog() for details. If 'g:vimyaForceRefresh' is set,
    vimyaRefreshLog() will be called after waiting for 'g:vimyaRefreshWait' seconds after all
    commands have been sent to Maya. Note that if a log file has been set and you close the log
    window, it will not be opened automatically, you may use vimyaOpenLog() to open it again.

    For backwards compatibility, this function is also available as sendBufferToMaya(). The usage
    is exactly the same as for vimyaRun().

    Returns False if an error occured, else True.
    """

    global __vimyaLogPath, __vimyaTempFiles

    filetype = vim.eval ('&filetype')
    if filetype not in ['', 'mel', 'python']:
        return __vimyaError ('Error: Supported filetypes: "python", "mel", None.')

    if __vimyaLogPath == '':
        if not vimyaResetLog ():
            return False

    tempDir = vim.eval ('g:vimyaTempDir')
    if tempDir != '':
        tempfile.tempdir = tempDir
    else:
        tempfile.tempdir = None

    (tmpHandle, tmpPath) = tempfile.mkstemp (suffix = '.tmp', prefix = 'vimya.', text = 1)
    __vimyaTempFiles.append (tmpPath)

    try:
        if userCmd:
            os.write (tmpHandle, (userCmd+'\n').encode())
        else:
            vStart = vim.current.buffer.mark ('<')
            if (vStart is None) or (forceBuffer):
                for line in vim.current.buffer:
                    os.write (tmpHandle, (line+'\n').encode())
            else:
                vEnd = vim.current.buffer.mark ('>')
                for line in vim.current.buffer [vStart [0] - 1 : vEnd [0]]:
                    os.write (tmpHandle, (line+'\n').encode())
    finally:
        os.close (tmpHandle)

    commands = ['commandEcho -state on -lineNumbers on;']

    defaultType = vim.eval ('g:vimyaDefaultFiletype')
    escapedPath = __vimyaEscape (__vimyaFixPath (tmpPath), '\\"')

    if filetype == 'python' or (filetype == '' and defaultType == 'python'):
        try:
            commands.append ('python ("exec(open(\\"%s\\").read())");' % escapedPath)
        except:
            commands.append ('python ("execfile (\\"%s\\")");' % escapedPath)
    elif filetype == 'mel' or (filetype == '' and defaultType == 'mel'):
        commands.append ('source "%s";' % escapedPath)

    commands.append ('commandEcho -state off -lineNumbers off;')
    commands.append ('sysFile -delete "%s";' % escapedPath)

    sent = vimyaSend (commands)
    if sent != len (commands):
        return __vimyaError ('%d commands out of %d sent successfully.' % (sent, len (commands)))

    refresh = int   (vim.eval ('g:vimyaForceRefresh'))
    wait    = float (vim.eval ('g:vimyaRefreshWait' ))
    if __vimyaLogPath != '' and refresh:
        time.sleep (wait)
        return vimyaRefreshLog ()

    return True

# For backwards comapatibility, sendBufferToMaya() will be an alias for vimyaRun():

sendBufferToMaya = vimyaRun

EOP

" vim: set et si nofoldenable ft=python sts=4 sw=4 tw=99 ts=4 fenc=utf8 :
