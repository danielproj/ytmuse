// Native UI-test setup only. Never linked into YTMuse or its package targets.
import Carbon
import Foundation

func identifier(_ source: TISInputSource) -> String {
  let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!
  return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}
func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
  guard let value = TISGetInputSourceProperty(source, key) else { return false }
  return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
}
if CommandLine.arguments.count == 1 {
  print(identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
} else {
  let requested = CommandLine.arguments[1]
  let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
  let eligible = sources.filter {
    flag($0, kTISPropertyInputSourceIsEnabled) && flag($0, kTISPropertyInputSourceIsSelectCapable)
  }
  let source =
    requested == "--ascii"
    ? eligible.first(where: { flag($0, kTISPropertyInputSourceIsASCIICapable) })
    : eligible.first(where: { identifier($0) == requested })
  guard let source else {
    fputs("Requested source is not already enabled/selectable.\n", stderr)
    exit(75)
  }
  let status = TISSelectInputSource(source)
  guard status == noErr else {
    fputs("Input source selection failed.\n", stderr)
    exit(75)
  }
  guard identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == identifier(source)
  else {
    fputs("Input source selection did not become current.\n", stderr)
    exit(75)
  }
  print(identifier(source))
}
