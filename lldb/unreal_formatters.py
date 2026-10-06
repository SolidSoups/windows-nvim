# Wraps Unreal's LLDB formatters (Engine/Extras/LLDBDataFormatters/UEDataFormatters_2ByteChars.py) for lldb-dap on
# Windows. Loaded from lua/config/unreal.lua, which registers this module's providers under Unreal's commands.
#
# - lldb-dap builds every child of a variable before it answers, so a container whose size reads wrong freezes the
#   editor until it's done. A range-for's hidden TArray reference read as size=2621448 with 2 elements, and that
#   froze a session for minutes. Child counts are capped here.
# - That bad size came through a reference, so references are dereferenced before Unreal's code sees them.
# - PDB debug info carries no template arguments, so SBType.GetTemplateArgumentType comes back empty, and Unreal's
#   container providers can't find their element type: a TArray shows its raw members and no elements. The type
#   name still spells the arguments out, so they're parsed from it and looked up by name instead.
# - Two additions at the bottom: enum names for TEnumAsByte, and one-line summaries for vectors and rotators.

import re

import lldb
import UEDataFormatters_2ByteChars as ue

# LLDB's own default for target.max-children-count is 256; a bit more room for real arrays
MAX_CHILDREN = 1000


def _template_args(type_name):
    # "TArray<TEnumAsByte<ECollisionChannel>, TSizedDefaultAllocator<32>>" -> the top-level arguments
    name = type_name.strip()
    start = name.find('<')
    if start < 0 or not name.endswith('>'):
        return []
    args, depth, current = [], 0, ''
    for ch in name[start + 1:-1]:
        if ch in '<(':
            depth += 1
        elif ch in '>)':
            depth -= 1
        if ch == ',' and depth == 0:
            args.append(current.strip())
            current = ''
        else:
            current += ch
    if current.strip():
        args.append(current.strip())
    return args


def _target():
    return lldb.debugger.GetSelectedTarget()


# built-in types aren't records in the PDB, so a name lookup misses some of them (unsigned __int64)
_BASIC_TYPES = {
    'bool': lldb.eBasicTypeBool,
    'char': lldb.eBasicTypeChar,
    'signed char': lldb.eBasicTypeSignedChar,
    'unsigned char': lldb.eBasicTypeUnsignedChar,
    'wchar_t': lldb.eBasicTypeWChar,
    'char16_t': lldb.eBasicTypeChar16,
    'char32_t': lldb.eBasicTypeChar32,
    'short': lldb.eBasicTypeShort,
    'unsigned short': lldb.eBasicTypeUnsignedShort,
    'int': lldb.eBasicTypeInt,
    'unsigned int': lldb.eBasicTypeUnsignedInt,
    'long': lldb.eBasicTypeLong,
    'unsigned long': lldb.eBasicTypeUnsignedLong,
    '__int64': lldb.eBasicTypeLongLong,
    'long long': lldb.eBasicTypeLongLong,
    'unsigned __int64': lldb.eBasicTypeUnsignedLongLong,
    'unsigned long long': lldb.eBasicTypeUnsignedLongLong,
    'float': lldb.eBasicTypeFloat,
    'double': lldb.eBasicTypeDouble,
}


def _msvc_spelling(text):
    # PDB names are spelled the way MSVC prints them, which differs from LLDB's spelling: enums inside template
    # arguments carry "enum ", pointers are "T *", const is "T const " with a trailing space, and nested closing
    # brackets are "> >"
    text = text.strip()
    pointers = 0
    while text.endswith('*'):
        pointers += 1
        text = text[:-1].rstrip()
    if text.endswith(' const'):
        spelled = _msvc_spelling(text[:-len(' const')]) + ' const '
    elif re.fullmatch(r'-?\d+[uUlL]*|true|false', text):
        spelled = text
    elif '<' in text and text.endswith('>'):
        args = [_msvc_spelling(a) for a in _template_args(text)]
        inner = ','.join(args)
        spelled = text[:text.find('<')] + '<' + inner + (' >' if inner.endswith('>') else '>')
    else:
        found = _target().FindFirstType(text)
        if found.IsValid() and found.GetTypeClass() == lldb.eTypeClassEnumeration:
            spelled = 'enum ' + text
        else:
            spelled = text
    return spelled + ' *' * pointers


def _find_type(text):
    # const doesn't change the layout, so it's dropped for the lookup
    text = text.strip()
    if text.startswith('const '):
        text = text[len('const '):]
    pointers = 0
    while text.endswith('*'):
        pointers += 1
        text = text[:-1].rstrip()
    if text.endswith(' const'):
        text = text[:-len(' const')]
    target = _target()
    if text in _BASIC_TYPES:
        found = target.GetBasicType(_BASIC_TYPES[text])
    else:
        found = target.FindFirstType(text)
    if not found.IsValid() and '<' in text:
        found = target.FindFirstType(_msvc_spelling(text))
    if not found.IsValid():
        # engine types the game's PDB only forward-declares can't be found without engine symbols. A pointer to one
        # still has a known size, so show it as an address
        if pointers == 0:
            return found
        found = target.GetBasicType(lldb.eBasicTypeVoid)
    for _ in range(pointers):
        found = found.GetPointerType()
    return found


_native_count = lldb.SBType.GetNumberOfTemplateArguments
_native_arg = lldb.SBType.GetTemplateArgumentType


def _count(self):
    count = _native_count(self)
    return count if count > 0 else len(_template_args(self.GetName()))


def _arg(self, index):
    found = _native_arg(self, index)
    if found.IsValid():
        return found
    args = _template_args(self.GetName())
    if index < len(args):
        return _find_type(args[index])
    return found


lldb.SBType.GetNumberOfTemplateArguments = _count
lldb.SBType.GetTemplateArgumentType = _arg


def _deref(valobj):
    if valobj.GetType().IsReferenceType():
        return valobj.Dereference()
    return valobj


def _wrap_summary(provider):
    def summary(valobj, internal_dict):
        return provider(_deref(valobj), internal_dict)
    return summary


def _wrap_synth(base):
    class Capped(base):
        def __init__(self, valobj, internal_dict):
            base.__init__(self, _deref(valobj), internal_dict)

        def num_children(self, max_count=None):
            return max(0, min(base.num_children(self), MAX_CHILDREN))
    Capped.__name__ = base.__name__
    return Capped


# same names as Unreal's module, so its registration commands only need the module name swapped
for _name, _value in vars(ue).items():
    if _name.endswith('SummaryProvider') and callable(_value):
        globals()[_name] = _wrap_summary(_value)
    elif _name.endswith('SynthProvider') and isinstance(_value, type):
        globals()[_name] = _wrap_synth(_value)


# Additions Unreal's script doesn't have. lua/config/unreal.lua registers these after Unreal's own


def TEnumAsByteSummaryProvider(valobj, internal_dict):
    # "ECC_GameTraceChannel4 (17)" instead of the raw byte '\x11'
    valobj = _deref(valobj)
    number = valobj.GetChildMemberWithName('Value').GetValueAsUnsigned(0)
    enum_type = valobj.GetType().GetCanonicalType().GetUnqualifiedType().GetTemplateArgumentType(0)
    if enum_type.IsValid():
        members = enum_type.GetEnumMembers()
        for i in range(members.GetSize()):
            member = members.GetTypeEnumMemberAtIndex(i)
            if member.GetValueAsUnsigned() == number:
                return '%s (%d)' % (member.GetName(), number)
    return str(number)


_MATH_FIELDS = {
    'TVector': ('X', 'Y', 'Z'),
    'TVector2': ('X', 'Y'),
    'TVector4': ('X', 'Y', 'Z', 'W'),
    'TRotator': ('Pitch', 'Yaw', 'Roll'),
    'TQuat': ('X', 'Y', 'Z', 'W'),
}


def MathSummaryProvider(valobj, internal_dict):
    # "(X=1.000, Y=2.000, Z=3.000)", the precision of Unreal's own ToString, so vectors read without expanding
    valobj = _deref(valobj)
    name = valobj.GetType().GetCanonicalType().GetUnqualifiedType().GetName()
    fields = _MATH_FIELDS.get(name[:name.find('<')].split('::')[-1], ())
    parts = []
    for field in fields:
        try:
            number = float(valobj.GetChildMemberWithName(field).GetValue())
        except (TypeError, ValueError):
            return None
        parts.append('%s=%.3f' % (field, number))
    return '(' + ', '.join(parts) + ')' if parts else None
