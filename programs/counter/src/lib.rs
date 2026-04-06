use borsh::{BorshDeserialize, BorshSerialize};
use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    msg,
    program_error::ProgramError,
    pubkey::Pubkey,
};

// Placeholder program ID - replace with actual deployed address
solana_program::declare_id!("CounterProgram11111111111111111111111111111");

/// Account data structure stored on-chain.
#[derive(BorshSerialize, BorshDeserialize, Debug)]
pub struct CounterAccount {
    pub counter: u64,
}

/// Supported instructions.
/// v1: Increment only
/// v2: Increment + Reset
pub enum CounterInstruction {
    /// Increments the counter by 1.
    Increment,
    /// Resets the counter to 0 (added in v2).
    Reset,
}

impl CounterInstruction {
    /// Decode instruction data into a CounterInstruction variant.
    pub fn unpack(input: &[u8]) -> Result<Self, ProgramError> {
        let (&tag, _rest) = input
            .split_first()
            .ok_or(ProgramError::InvalidInstructionData)?;

        match tag {
            0 => Ok(CounterInstruction::Increment),
            1 => Ok(CounterInstruction::Reset),
            _ => {
                msg!("Error: Unknown instruction tag: {}", tag);
                Err(ProgramError::InvalidInstructionData)
            }
        }
    }
}

entrypoint!(process_instruction);

/// Program entrypoint.
pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    msg!("Counter program invoked");

    let instruction = CounterInstruction::unpack(instruction_data)?;

    let accounts_iter = &mut accounts.iter();
    let counter_account = next_account_info(accounts_iter)?;

    // Validate that the account is owned by this program
    if counter_account.owner != program_id {
        msg!("Error: Counter account is not owned by this program");
        return Err(ProgramError::IncorrectProgramId);
    }

    // Validate that the account is writable
    if !counter_account.is_writable {
        msg!("Error: Counter account must be writable");
        return Err(ProgramError::InvalidAccountData);
    }

    // Validate that the caller is a signer (first remaining account or the counter account itself)
    // For simplicity, we require at least one signer in the transaction
    let signer_account = if counter_account.is_signer {
        counter_account
    } else {
        let signer = next_account_info(accounts_iter)?;
        if !signer.is_signer {
            msg!("Error: Transaction must be signed");
            return Err(ProgramError::MissingRequiredSignature);
        }
        signer
    };
    msg!("Signer: {}", signer_account.key);

    // Deserialize or initialize counter account data
    let mut counter_data = if counter_account.data_len() == 0 {
        msg!("Error: Counter account has no data allocated");
        return Err(ProgramError::UninitializedAccount);
    } else {
        let data = counter_account.try_borrow_data()?;
        // If data is all zeros, treat as freshly initialized
        if data.iter().all(|&b| b == 0) {
            CounterAccount { counter: 0 }
        } else {
            CounterAccount::try_from_slice(&data).map_err(|e| {
                msg!("Error: Failed to deserialize counter account: {}", e);
                ProgramError::InvalidAccountData
            })?
        }
    };

    match instruction {
        CounterInstruction::Increment => {
            counter_data.counter = counter_data
                .counter
                .checked_add(1)
                .ok_or_else(|| {
                    msg!("Error: Counter overflow");
                    ProgramError::InvalidAccountData
                })?;
            msg!("Counter incremented to: {}", counter_data.counter);
        }
        CounterInstruction::Reset => {
            msg!(
                "Counter reset from {} to 0 (v2 feature)",
                counter_data.counter
            );
            counter_data.counter = 0;
        }
    }

    // Serialize the updated data back into the account
    let serialized = borsh::to_vec(&counter_data).map_err(|e| {
        msg!("Error: Failed to serialize counter account: {}", e);
        ProgramError::InvalidAccountData
    })?;

    let mut account_data = counter_account.try_borrow_mut_data()?;
    if serialized.len() > account_data.len() {
        msg!("Error: Account data too small for serialized state");
        return Err(ProgramError::AccountDataTooSmall);
    }
    account_data[..serialized.len()].copy_from_slice(&serialized);

    Ok(())
}
