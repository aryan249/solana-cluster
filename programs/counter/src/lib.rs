use borsh::{BorshDeserialize, BorshSerialize};
use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    msg,
    program_error::ProgramError,
    pubkey::Pubkey,
};

/// Counter state stored on-chain.
#[derive(BorshSerialize, BorshDeserialize, Debug)]
pub struct CounterAccount {
    pub count: u64,
}

entrypoint!(process_instruction);

pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    let accounts_iter = &mut accounts.iter();
    let counter_account = next_account_info(accounts_iter)?;

    if counter_account.owner != program_id {
        msg!("Error: account not owned by this program");
        return Err(ProgramError::IncorrectProgramId);
    }

    if !counter_account.is_writable {
        return Err(ProgramError::InvalidAccountData);
    }

    let instruction = instruction_data
        .first()
        .ok_or(ProgramError::InvalidInstructionData)?;

    let mut counter = if counter_account.data.borrow().iter().all(|&b| b == 0) {
        CounterAccount { count: 0 }
    } else {
        CounterAccount::try_from_slice(&counter_account.data.borrow()).map_err(|e| {
            msg!("Failed to deserialize: {}", e);
            ProgramError::InvalidAccountData
        })?
    };

    match instruction {
        0 => {
            counter.count = counter.count.checked_add(1).ok_or(ProgramError::InvalidAccountData)?;
            msg!("Incremented counter to {}", counter.count);
        }
        // V2: uncomment the next 4 lines to enable reset
        // 1 => {
        //     counter.count = 0;
        //     msg!("Reset counter to 0");
        // }
        _ => {
            msg!("Invalid instruction: {}", instruction);
            return Err(ProgramError::InvalidInstructionData);
        }
    }

    counter.serialize(&mut &mut counter_account.data.borrow_mut()[..])?;
    Ok(())
}
