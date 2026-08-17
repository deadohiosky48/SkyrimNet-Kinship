#include "PapyrusBridge.h"

#include "PCH.h"

namespace Kinship::PapyrusBridge {

    namespace {
        constexpr auto kScript = "SNKin_Bridge";

        // Papyrus dispatch is asynchronous and its result is not marshalled
        // back in any useful form - the web API has the same limitation, where
        // every call returns 0 whether it succeeded, failed, or was handed a
        // deliberately invalid name. The log is the only ground truth, so this
        // callback exists purely to satisfy the signature.
        class NullCallback : public RE::BSScript::IStackCallbackFunctor {
        public:
            void operator()(RE::BSScript::Variable) override {}
            bool CanSave() const override { return false; }
            void SetObject(const RE::BSTSmartPointer<RE::BSScript::Object>&) override {}
        };

        RE::BSScript::Internal::VirtualMachine* VM() {
            return RE::BSScript::Internal::VirtualMachine::GetSingleton();
        }
    }

    bool IsAvailable() {
        auto* vm = VM();
        if (!vm) {
            return false;
        }
        // A loaded type info for our script is the cheapest proof the mod's
        // Papyrus half is actually present. Without it the panel should render
        // read-only rather than offering writes that vanish.
        RE::BSTSmartPointer<RE::BSScript::ObjectTypeInfo> typeInfo;
        return vm->GetScriptObjectType(kScript, typeInfo);
    }

    bool SetParentById(const std::string& aChildName, std::int32_t aParentFormID, std::int32_t aIsFather) {
        auto* vm = VM();
        if (!vm || aChildName.empty()) {
            return false;
        }

        // NOTE the FormID is passed as a SIGNED 32-bit int, because Papyrus has
        // no unsigned type. 0xFE21C812 arrives as -31307758 and Game.GetFormEx
        // handles the full range on the other side. Passing it unsigned
        // overflows and resolves to nothing - the same trap the PowerShell
        // helper documents.
        auto callback = RE::BSTSmartPointer<RE::BSScript::IStackCallbackFunctor>(new NullCallback());
        auto args = RE::MakeFunctionArguments(
            std::string(aChildName),
            std::int32_t(aParentFormID),
            std::int32_t(aIsFather));

        return vm->DispatchStaticCall(kScript, "SetParentByIdStatic", args, callback);
    }

    bool ForgetFutureChildren() {
        auto* vm = VM();
        if (!vm) {
            return false;
        }
        auto callback = RE::BSTSmartPointer<RE::BSScript::IStackCallbackFunctor>(new NullCallback());
        auto args = RE::MakeFunctionArguments();
        return vm->DispatchStaticCall(kScript, "ForgetFutureChildren", args, callback);
    }

    bool AddChild(const std::string& aChildName, std::int32_t aChildFormID,
                  std::int32_t aMotherFormID, std::int32_t aFatherFormID) {
        auto* vm = VM();
        if (!vm || aChildName.empty()) {
            return false;
        }
        auto callback = RE::BSTSmartPointer<RE::BSScript::IStackCallbackFunctor>(new NullCallback());
        auto args = RE::MakeFunctionArguments(
            std::string(aChildName),
            std::int32_t(aChildFormID),
            std::int32_t(aMotherFormID),
            std::int32_t(aFatherFormID));
        return vm->DispatchStaticCall(kScript, "AddChildStatic", args, callback);
    }

    bool ClearParent(const std::string& aChildName, std::int32_t aIsFather) {
        auto* vm = VM();
        if (!vm || aChildName.empty()) {
            return false;
        }
        // ClearParentStatic, not ClearParent. Scaffolding this DLL is what
        // exposed that the clear path had only an INSTANCE entry point, which
        // DispatchStaticCall cannot reach - so the Papyrus side gained a Global
        // twin rather than this side hardcoding our plugin filename to resolve
        // the quest.
        auto callback = RE::BSTSmartPointer<RE::BSScript::IStackCallbackFunctor>(new NullCallback());
        auto args = RE::MakeFunctionArguments(
            std::string(aChildName),
            std::int32_t(aIsFather));

        return vm->DispatchStaticCall(kScript, "ClearParentStatic", args, callback);
    }
}
